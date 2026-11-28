import Foundation
import Network
import Combine
import Photos
import UniformTypeIdentifiers
import CryptoKit

/// What the person picked to send: a file in Files, or a Photo Library item
/// (its identifier when Porthole can read the library, and the picker's
/// provider as the fallback).
enum SendPick {
    case file(URL)
    case photo(identifier: String?, provider: NSItemProvider?)
}

/// Uses the paired PC's pinned inbox and the per-file acknowledgements used by Share › Porthole.
/// File bodies are streamed; history is updated only after the PC returns OK.
final class OutboundFileSender: ObservableObject {
    private static var privateContainer: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortholeTransfers", isDirectory: true)
    }

    static var storageContainers: [URL] {
        [PortholeAppGroup.containerURL, privateContainer].compactMap { $0 }
    }

    private static func pending(for peer: TrustedPeer) -> (OutboundTransferJournal.Batch, OutboundTransferManifest)? {
        for container in storageContainers {
            if let pending = OutboundTransferJournal(container: container).openPending(for: peer) { return pending }
        }
        return nil
    }

    enum Phase: Equatable { case idle, preparing, ready, sending, sent, failed, cancelled }
    struct Item: Identifiable {
        let id: UUID
        var url: URL
        var name: String
        var bytes: Int64
        var digest: String
        var sent = false
        var source: TransferSource = .staged
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [Item] = []
    @Published private(set) var progress: Double = 0
    @Published private(set) var message = ""
    @Published private(set) var pendingCount = 0
    /// The item being sent, how far into it, and the whole send in bytes.
    @Published private(set) var activeItemID: UUID?
    @Published private(set) var activeFraction: Double = 0
    @Published private(set) var sentBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var secondsLeft: Double?
    private let queue = DispatchQueue(label: "porthole.sendFiles")
    private let preparation = PreparationCancellation()
    private var generation = UUID()
    private var files: [Item] = []
    private var journalBatch: OutboundTransferJournal.Batch?
    private var manifest: OutboundTransferManifest?
    private var link: NWConnection?
    private let readerLock = NSLock()
    private var currentReader: TransferBodyReader?
    /// Reading the item being sent; replacing it closes the old one.
    private var reader: TransferBodyReader? {
        get { readerLock.lock(); defer { readerLock.unlock() }; return currentReader }
        set {
            readerLock.lock()
            let old = currentReader
            currentReader = newValue
            readerLock.unlock()
            if let old, old !== newValue { old.close() }
        }
    }
    private var batchBytes: Int64 = 0
    private var doneBytes: Int64 = 0
    private var activeIndex: Int?
    private var activeDone: Int64 = 0
    private var rateBase: (at: DispatchTime, bytes: Int64)?
    private var smoothedLeft: Double?
    private var buffer = Data()
    private var timer: DispatchWorkItem?
    private var batch: [Int] = []
    private var destination: TrustedPeer?
    private var verifiedPeer: TrustedPeer?
    private var protocolVersion: Int?
    private var resumable: Bool { (protocolVersion ?? 1) >= 2 }
    private var awaitingReceipt = false
    /// Version 4: the checksum of the file being sent, taken as it goes.
    private var bodyHash: SHA256?
    /// Bytes of the active file not read yet, and pieces on their way.
    private var unread: Int64 = 0
    private var inFlight = 0
    private var fileStartedAt: Date?
    private var watching = false
    private var lineWaiter: (() -> Void)?
    private var startOffset: Int64 = 0
    private var lastProgressAt = DispatchTime.now()
    private var onSaved: (() -> Void)?

    func prepare(_ urls: [URL], for peer: TrustedPeer) {
        prepare(urls.map(SendPick.file), for: peer)
    }

    /// Reads each pick once for its size and checksum. Files and Photo
    /// Library items are not copied: they are read again from where they are
    /// when sent, so a retry works later and nothing takes extra space.
    func prepare(_ picks: [SendPick], for peer: TrustedPeer) {
        let attempt = preparation.begin()
        queue.async {
            self.cleanUp()
            self.publish(.preparing, message: "Preparing…")
            do {
                guard !picks.isEmpty else { throw SendError.message("Nothing selected.") }
                guard picks.count <= TransferStaging.maxItems else { throw SendError.message("Send up to 500 items at a time.") }
                let journal = OutboundTransferJournal(container: PortholeAppGroup.containerURL ?? Self.privateContainer)
                let batch = try journal.makeBatch(for: peer)
                self.journalBatch = batch
                self.destination = peer.remembered
                var remaining = TransferStaging.maxBatchBytes
                let cancelled = { self.preparation.isCancelled(attempt) || batch.isRevoked }
                // A PC that takes the checksum after the file needs only the
                // size now: nothing is read before sending starts.
                let quick = peer.receiveVersion >= 4
                for (index, pick) in picks.enumerated() {
                    if cancelled() { throw TransferStaging.Failure.cancelled }
                    if picks.count > 1 { self.publish(.preparing, message: "Preparing \(index + 1) of \(picks.count)…") }
                    let began = Date()
                    var how = "file"
                    let item: Item
                    switch pick {
                    case .file(let url):
                        item = try Self.original(url, index: index, batch: batch, quick: quick, cancelled: cancelled)
                    case .photo(let identifier, let provider):
                        if let identifier, let photo = try Self.libraryItem(identifier, index: index, batch: batch,
                                                                             quick: quick, cancelled: cancelled) {
                            item = photo
                            how = "photo library"
                        } else if let provider {
                            how = "copy from the picker"
                            item = try Self.copy(provider, index: index, batch: batch, remaining: remaining,
                                                 quick: quick, cancelled: cancelled)
                            remaining -= item.bytes
                        } else {
                            throw SendError.message("This item is no longer in your Photo Library.")
                        }
                    }
                    self.files.append(item)
                    DiagnosticLog.note(String(format: "send: prepared %@ (%lld bytes, %@%@) in %.1f s", item.name, item.bytes,
                                              how, item.digest.isEmpty ? ", checksum while sending" : ", read through first",
                                              Date().timeIntervalSince(began)))
                }
                if cancelled() { throw TransferStaging.Failure.cancelled }
                let manifest = OutboundTransferManifest(id: batch.id, destination: peer.remembered,
                                                        files: self.files.map { file in
                    .init(id: file.id, name: file.name, bytes: file.bytes, digest: file.digest, sent: false,
                          source: file.source.isStaged ? nil : file.source)
                })
                let reviewed = try batch.saveSelection(manifest, version: peer.receiveVersion)
                self.files = reviewed.files.enumerated().map { index, file in
                    Item(id: file.id, url: batch.itemURL(named: file.name, index: index), name: file.name,
                         bytes: file.bytes, digest: file.digest, source: file.source ?? .staged)
                }
                self.manifest = reviewed
                self.protocolVersion = reviewed.version
                self.publish(.ready, message: "")
            } catch {
                self.cleanUp()
                if self.preparation.isCancelled(attempt) { self.publish(.cancelled, message: "") }
                else { self.fail(error.localizedDescription) }
            }
        }
    }

    /// A file picked in Files: measured where it is and kept as a bookmark.
    private static func original(_ url: URL, index: Int, batch: OutboundTransferJournal.Batch, quick: Bool,
                                 cancelled: @escaping () -> Bool) throws -> Item {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData()
        let name = TransferFileName.make(url.lastPathComponent, index: index)
        if quick, let bytes = localSize(of: url), bytes > 0 {
            return Item(id: UUID(), url: batch.itemURL(named: name, index: index), name: name, bytes: bytes,
                        digest: "", source: .file(bookmark: bookmark))
        }
        var coordinatorError: NSError?
        var measured: Result<(bytes: Int64, digest: String), Error>?
        // Coordinated, so a file still in iCloud Drive is downloaded first.
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinated in
            measured = Result {
                let reader = try FileBodyReader(url: coordinated)
                defer { reader.close() }
                return try TransferMeasure.measure(reader, cancelled: cancelled)
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let measured else { throw SendError.message("Unable to read \(name).") }
        let result = try measured.get()
        return Item(id: UUID(), url: batch.itemURL(named: name, index: index), name: name, bytes: result.bytes,
                    digest: result.digest, source: .file(bookmark: bookmark))
    }

    /// The size of a file already on this iPhone (not one still in iCloud).
    private static func localSize(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { return nil }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return nil }
        return Int64(size)
    }

    /// A Photo Library item, read from the library itself. Nil when this
    /// iPhone does not let Porthole read it (limited access).
    private static func libraryItem(_ identifier: String, index: Int, batch: OutboundTransferJournal.Batch,
                                    quick: Bool, cancelled: @escaping () -> Bool) throws -> Item? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let resource = PhotoBodyReader.resource(of: asset, named: nil) else { return nil }
        let name = TransferFileName.make(resource.originalFilename, index: index)
        if quick, let bytes = PhotoLibraryLookup.size(of: resource), bytes > 0 {
            return Item(id: UUID(), url: batch.itemURL(named: name, index: index), name: name, bytes: bytes,
                        digest: "", source: .photo(asset: identifier, resource: resource.originalFilename))
        }
        let reader = try PhotoBodyReader(asset: identifier, resource: resource.originalFilename)
        defer { reader.close() }
        let measured = try TransferMeasure.measure(reader, cancelled: cancelled)
        return Item(id: UUID(), url: batch.itemURL(named: name, index: index), name: name, bytes: measured.bytes,
                    digest: measured.digest, source: .photo(asset: identifier, resource: resource.originalFilename))
    }

    /// The picker's own copy, when the library itself can't be read.
    private static func copy(_ provider: NSItemProvider, index: Int, batch: OutboundTransferJournal.Batch,
                             remaining: Int64, quick: Bool, cancelled: @escaping () -> Bool) throws -> Item {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        guard let type = types.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .image) }) ?? types.first else {
            throw SendError.message("This item can't be sent.")
        }
        let done = DispatchSemaphore(value: 0)
        var result: Result<Item, Error> = .failure(SendError.message("Unable to prepare this item."))
        _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
            defer { done.signal() }
            guard let url else {
                result = .failure(error ?? SendError.message("Unable to prepare this item."))
                return
            }
            result = Result {
                var wanted = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                if (wanted as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty {
                    wanted += ".\(url.pathExtension)"
                }
                let name = TransferFileName.make(wanted, index: index)
                let directory = batch.folder.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent(name)
                if quick, let moved = try? TransferMeasure.takeOver(url, to: target) {
                    return Item(id: UUID(), url: target, name: name, bytes: moved, digest: "")
                }
                let snapshot = try TransferStaging.snapshot(url, to: target, remaining: remaining,
                                                            reserve: batch.reserve, cancelled: cancelled)
                return Item(id: UUID(), url: target, name: name, bytes: snapshot.bytes, digest: snapshot.digest)
            }
        }
        done.wait()
        return try result.get()
    }

    func refreshPending(for peer: TrustedPeer?) {
        queue.async {
            // The file transfer has its own connection: a moment without
            // Porthole's link to the PC doesn't stop it. Only another PC does.
            if peer != nil || self.link == nil { self.verifiedPeer = peer }
            if self.link != nil, let peer, let destination = self.destination, !destination.samePairing(as: peer) {
                self.fail("The PC changed. Choose the files again to send them to this PC.")
            }
            let count = peer.flatMap { Self.pending(for: $0)?.1.pendingCount } ?? 0
            DispatchQueue.main.async { self.pendingCount = count }
        }
    }

    func restorePending(for peer: TrustedPeer) {
        queue.async {
            guard self.link == nil else { return } // sending now: keep it
            self.cleanUp()
            guard let (batch, manifest) = Self.pending(for: peer) else {
                self.publish(.failed, message: "This transfer is unavailable or open in another Porthole window.")
                return
            }
            self.journalBatch = batch
            self.manifest = manifest
            self.destination = manifest.destination
            self.protocolVersion = manifest.version
            self.files = manifest.files.enumerated().map { index, file in
                Item(id: file.id, url: batch.itemURL(named: file.name, index: index), name: file.name,
                     bytes: file.bytes, digest: file.digest, sent: file.sent, source: file.source ?? .staged)
            }
            self.publish(.failed, message: "")
        }
    }

    func send(to peer: TrustedPeer, onSaved: @escaping () -> Void) {
        queue.async {
            guard self.link == nil, !self.files.isEmpty else { return }
            guard !self.files.contains(where: { !$0.sent && $0.bytes > TransferStaging.desktopFileBytes }) else {
                self.fail(TransferStaging.Failure.desktopFileLimit.localizedDescription)
                return
            }
            guard let current = self.verifiedPeer, current.samePairing(as: peer),
                  current.channelTicket != nil else {
                self.fail("Reconnect to the reviewed PC and retry. Choose the files again to send them to another PC.")
                return
            }
            guard self.checkRevocation() else { return }
            if let destination = self.destination, !destination.samePairing(as: current) {
                self.fail("This transfer belongs to \(destination.name). Start a new transfer to use another PC.")
                return
            }
            let version = self.protocolVersion ?? current.receiveVersion
            guard version >= 2, current.receiveVersion >= version,
                  let batch = self.journalBatch, var manifest = self.manifest else {
                self.fail("Waiting for file transfer support from the paired PC. Retry after reconnecting.")
                return
            }
            manifest.version = version
            do { try batch.save(manifest) }
            catch { self.fail("Unable to save the transfer state on this iPhone."); return }
            self.manifest = manifest
            self.destination = current
            self.protocolVersion = version
            self.batch = self.files.indices.filter { !self.files[$0].sent }
            guard !self.batch.isEmpty else { return }
            self.batchBytes = self.batch.reduce(0) { $0 + self.files[$1].bytes }
            self.doneBytes = 0
            self.activeIndex = nil
            self.activeDone = 0
            self.rateBase = nil
            self.smoothedLeft = nil
            let first = self.files[self.batch[0]].name
            let more = self.batch.count - 1
            BackgroundSend.shared.begin(title: "Sending to \(current.name)",
                                        subtitle: more > 0 ? "\(first) and \(more) more" : first) { [weak self] byPerson in
                // The stop button cancels; iOS giving up only pauses.
                if byPerson { self?.cancel() } else { self?.pauseForBackground() }
            }
            SendNotice.clear()
            self.onSaved = onSaved
            self.buffer = Data()
            let token = self.generation
            let connection = TrustedPeerTransport.connection(to: current, port: 47733)
            self.link = connection
            self.publish(.sending, progress: 0, message: "Connecting to \(peer.name)…")
            self.armTimeout(token)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, self.generation == token, self.link === connection else { return }
                if case .ready = state {
                    guard let connection else { return }
                    self.armTimeout(token)
                    TrustedPeerTransport.authenticate(connection: connection, peer: current) { authorized in
                        self.queue.async {
                            guard self.generation == token, self.link === connection else { return }
                            guard authorized else { self.fail("The PC did not authorize this transfer. Reconnect in Porthole and retry."); return }
                            guard let verified = self.verifiedPeer, verified.samePairing(as: current) else {
                                self.fail("The paired PC changed before the transfer started."); return
                            }
                            self.write(Data("PSHR \(version) \(self.batch.count)\n".utf8), token: token) {
                                self.sendFile(0, token: token)
                            }
                        }
                    }
                } else if case .failed = state { self.fail("PC connection lost. Connect Porthole on both devices and retry.") }
            }
            connection.start(queue: self.queue)
        }
    }

    func cancel() {
        preparation.cancel()
        // A Photo Library read may be waiting on Photos: let it go at once.
        (reader as? PhotoBodyReader)?.close()
        BackgroundSend.shared.finish(success: false)
        queue.async {
            guard self.link != nil || !self.files.isEmpty else { return }
            let uncertain = self.awaitingReceipt && !self.resumable
            self.stopConnection()
            self.dropUnsentOnPC()
            try? self.journalBatch?.discard()
            self.journalBatch = nil
            DispatchQueue.main.async { self.pendingCount = 0 }
            if !self.files.isEmpty, self.files.allSatisfy(\.sent) {
                self.publish(.sent, progress: 1, message: "All files have already been saved on your PC.")
            } else if uncertain {
                self.publish(.cancelled, message: "Transfer cancelled while confirming a file. Check the PC before retrying that file.")
            } else {
                self.publish(.cancelled, message: "Sending cancelled. Items already sent stay on the PC.")
            }
        }
    }

    /// Stops sending for now, ready to continue where it stopped.
    func pause() {
        (reader as? PhotoBodyReader)?.close()
        queue.async {
            guard self.link != nil else { return }
            self.stopConnection()
            BackgroundSend.shared.finish(success: false)
            self.publish(.failed, message: "")
            guard !BackgroundSend.appInForeground else { return }
            Self.notify(about: self.files.first(where: { !$0.sent })) { SendNotice.stopped(thumbnail: $0) }
        }
    }

    func reset() {
        preparation.cancel()
        queue.async { self.cleanUp(); self.publish(.idle, message: "") }
    }

    /// Cancel Sending: cancelled means gone, on this iPhone and the PC.
    func discardPending() {
        preparation.cancel()
        (reader as? PhotoBodyReader)?.close()
        BackgroundSend.shared.finish(success: false)
        queue.async {
            self.stopConnection()
            self.dropUnsentOnPC()
            self.cleanUp(discard: true)
            self.publish(.idle, message: "")
            DispatchQueue.main.async { self.pendingCount = 0 }
        }
    }

    /// What reached the PC of the unsent files is deleted there, so nothing
    /// continues them later. Needs a PC that knows DROP (inbox 4).
    private func dropUnsentOnPC() {
        guard let target = verifiedPeer ?? self.destination, target.receiveVersion >= 4,
              target.channelTicket != nil else { return }
        TransferDrop.send(files.filter { !$0.sent }.map(\.id), to: target)
    }

    private func sendFile(_ cursor: Int, token: UUID) {
        guard generation == token, link != nil else { return }
        if cursor == batch.count {
            write(Data("DONE\n".utf8), token: token) {
                self.readLine(token: token) { line in
                    guard line == "BYE" else { self.fail("The PC did not confirm the transfer session."); return }
                    self.stopConnection()
                    self.publish(.sent, progress: 1, message: "")
                    self.announceSent()
                }
            }
            return
        }
        var file = files[batch[cursor]]
        activeIndex = batch[cursor]
        activeDone = 0
        bodyHash = protocolVersion == 4 ? SHA256() : nil
        do {
            // Picked for a newer PC and sent to an older one: it needs the
            // checksum first after all.
            if protocolVersion == 3, file.digest.isEmpty {
                let measuring = try Self.reader(for: file)
                defer { measuring.close() }
                file.digest = try TransferMeasure.measure(measuring, cancelled: { self.generation != token }).digest
                files[batch[cursor]].digest = file.digest
            }
            reader = try Self.reader(for: file)
        }
        catch { fail("\(file.name): \(error.localizedDescription)"); return }
        let ticket = file.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let header: String
        switch protocolVersion {
        case 4: header = "ITEM \(ticket) FILE \(file.bytes) \(file.name)\n"
        case 3: header = "ITEM \(ticket) \(file.digest) \(file.bytes) \(file.name)\n"
        case 2: header = "ITEM \(ticket) FILE \(file.bytes) \(file.name)\n"
        default: header = "FILE \(file.bytes) \(file.name)\n"
        }
        write(Data(header.utf8), token: token) {
            if !self.resumable { self.pump(cursor, remaining: file.bytes, token: token); return }
            // Continuing a large file, the PC first checks what it kept.
            self.readLine(token: token, wait: TransferStaging.receiptWait(file.bytes)) { response in
                if response == "SAVED" { self.accept(cursor, token: token); return }
                guard response.hasPrefix("OFFSET "), let offset = Int64(response.dropFirst(7)), (0...file.bytes).contains(offset) else {
                    self.fail("The PC could not resume this transfer."); return
                }
                // What the PC already has counts as sent, not toward the speed.
                self.activeDone = offset
                self.rateBase = nil
                if self.bodyHash != nil {
                    // The checksum covers the whole file: read again what the
                    // PC kept, without sending it.
                    self.hashKept(cursor, left: offset, token: token)
                    return
                }
                do { try self.reader?.seek(to: offset) }
                catch { self.fail("Unable to read \(file.name)."); return }
                self.pump(cursor, remaining: file.bytes - offset, token: token)
            }
        }
    }

    private func accept(_ cursor: Int, token: UUID) {
        awaitingReceipt = false
        reader = nil
        let index = batch[cursor], file = files[index]
        doneBytes += file.bytes
        activeIndex = nil
        activeDone = 0
        guard let journalBatch, var manifest else {
            fail("The PC saved this file. Porthole could not record the receipt. Retry to check it again.")
            return
        }
        do {
            try journalBatch.record(ShareReceipt(id: file.id, date: Date(), peerName: manifest.destination.name,
                                            name: file.name, bytes: file.bytes,
                                            pairingID: manifest.destination.stableID))
            manifest.files[index].sent = true
            try journalBatch.save(manifest)
        } catch {
            fail("The PC saved this file. Porthole could not record the receipt. Retry to check it again.")
            return
        }
        self.manifest = manifest
        files[index].sent = true
        let callback = onSaved
        DispatchQueue.main.async { callback?() }
        publish(.sending, progress: batchBytes > 0 ? Double(doneBytes) / Double(batchBytes) : 1, message: "")
        sendFile(cursor + 1, token: token)
    }

    /// Reads what the PC already has into the checksum, a piece per turn
    /// so the connection's own work goes on in between.
    private func hashKept(_ cursor: Int, left: Int64, token: UUID) {
        guard generation == token, link != nil else { return }
        let file = files[batch[cursor]]
        if left == 0 {
            pump(cursor, remaining: file.bytes - activeDone, token: token)
            return
        }
        armTimeout(token, seconds: 120)
        do {
            guard let data = try reader?.read(upTo: Int(min(left, 8 << 20))), !data.isEmpty else {
                fail("Unable to finish reading \(file.name)."); return
            }
            bodyHash?.update(data: data)
            queue.async { self.hashKept(cursor, left: left - Int64(data.count), token: token) }
        } catch { fail("\(file.name): \(error.localizedDescription)") }
    }

    /// Sends the rest of the file: `remaining` bytes from where the reader
    /// is. Up to three pieces are on their way at once, so reading the next
    /// overlaps sending this one; small pieces from Photos are joined first.
    private func pump(_ cursor: Int, remaining: Int64, token: UUID) {
        guard generation == token, link != nil else { return }
        unread = remaining
        watchForCancel(token)
        if fileStartedAt == nil {
            fileStartedAt = Date()
            startOffset = files[batch[cursor]].bytes - remaining
        }
        fill(cursor, token: token)
    }

    private func fill(_ cursor: Int, token: UUID) {
        guard generation == token, link != nil else { return }
        let file = files[batch[cursor]]
        while inFlight < 3, unread > 0 {
            let data: Data
            do { data = try readPiece(Int(min(unread, 1 << 20))) }
            catch { fail("\(file.name): \(error.localizedDescription)"); return }
            guard !data.isEmpty else { fail("Unable to finish reading \(file.name)."); return }
            unread -= Int64(data.count)
            bodyHash?.update(data: data)
            if unread == 0, bodyHash == nil { awaitingReceipt = true }
            inFlight += 1
            write(data, token: token) {
                self.inFlight -= 1
                self.activeDone += Int64(data.count)
                let now = DispatchTime.now()
                if now.uptimeNanoseconds - self.lastProgressAt.uptimeNanoseconds >= 150_000_000 {
                    self.lastProgressAt = now
                    self.measureRate(now)
                    let fraction = self.batchBytes > 0 ? Double(self.doneBytes + self.activeDone) / Double(self.batchBytes) : 0
                    self.publish(.sending, progress: fraction, message: "")
                    let sent = ByteCountFormatter.string(fromByteCount: self.doneBytes + self.activeDone, countStyle: .file)
                    let total = ByteCountFormatter.string(fromByteCount: self.batchBytes, countStyle: .file)
                    BackgroundSend.shared.update(fraction: fraction, subtitle: "\(file.name) · \(sent) of \(total)")
                }
                self.fill(cursor, token: token)
            }
            guard generation == token, link != nil else { return }
        }
        if unread == 0, inFlight == 0 { finishBody(cursor, token: token) }
    }

    /// Up to `count` bytes, joining the reader's smaller pieces.
    private func readPiece(_ count: Int) throws -> Data {
        guard let reader else { return Data() }
        var data = Data()
        while data.count < count {
            let part = try reader.read(upTo: count - data.count)
            if part.isEmpty { break }
            data.append(part)
        }
        return data
    }

    /// Every byte is out: the checksum (version 4), then the PC's answer.
    private func finishBody(_ cursor: Int, token: UUID) {
        guard generation == token, link != nil else { return }
        let file = files[batch[cursor]]
        reader = nil
        awaitingReceipt = true
        if let hash = bodyHash {
            bodyHash = nil
            let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
            write(Data("SUM \(hex)\n".utf8), token: token) { self.finishBody(cursor, token: token) }
            return
        }
        if let started = fileStartedAt {
            let seconds = max(0.001, Date().timeIntervalSince(started))
            DiagnosticLog.note(String(format: "send: %@ sent in %.1f s (%.1f MB/s); waiting for the PC to save it",
                                      file.name, seconds, Double(file.bytes - startOffset) / seconds / 1_000_000))
            fileStartedAt = nil
        }
        // The PC checks and saves the whole file before it answers.
        readLine(token: token, wait: TransferStaging.receiptWait(file.bytes)) { line in
            guard line == "OK" else { self.fail("The PC did not save \(file.name). Reconnect and retry unsent files."); return }
            self.accept(cursor, token: token)
        }
    }

    private func write(_ data: Data, token: UUID, then completion: @escaping () -> Void) {
        guard generation == token, let connection = link else { return }
        guard checkRevocation() else { return }
        if let verifiedPeer, let destination, !verifiedPeer.samePairing(as: destination) {
            fail("The PC changed. Choose the files again to send them to this PC.")
            return
        }
        armTimeout(token)
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, self.generation == token, self.link === connection else { return }
            if error != nil { self.fail("Connection lost during transfer. Retry unsent files.") }
            else { completion() }
        })
    }

    private func readLine(token: UUID, wait seconds: Double = 30, completion: @escaping (String) -> Void) {
        armTimeout(token, seconds: seconds)
        readLineFragment(token: token, completion: completion)
    }

    private func readLineFragment(token: UUID, completion: @escaping (String) -> Void) {
        guard generation == token, let connection = link else { return }
        if let end = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: end) <= 128,
                  let text = String(data: buffer.prefix(upTo: end), encoding: .ascii) else { fail("Invalid PC response."); return }
            buffer.removeSubrange(buffer.startIndex...end)
            completion(text)
            return
        }
        guard buffer.count <= 128 else { fail("Invalid PC response."); return }
        if buffer.starts(with: Data("CANCELLED".utf8)) { cancelledOnPC(); return }
        // The listener started with the file gets the PC's next words.
        if watching {
            lineWaiter = { [weak self] in self?.readLineFragment(token: token, completion: completion) }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self, weak connection] data, _, complete, error in
            guard let self, self.generation == token, self.link === connection else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if (complete || error != nil) && !self.buffer.contains(10) { self.fail("PC connection closed before confirmation.") }
            else { self.readLineFragment(token: token, completion: completion) }
        }
    }

    /// Listens while the file goes: the PC may say CANCELLED (the person
    /// cancelled it there). Anything else waits for the line reader.
    private func watchForCancel(_ token: UUID) {
        guard generation == token, let connection = link, !watching else { return }
        watching = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self, weak connection] data, _, complete, error in
            guard let self else { return }
            self.watching = false
            guard self.generation == token, self.link === connection else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if self.buffer.starts(with: Data("CANCELLED".utf8)) { self.cancelledOnPC(); return }
            if let waiter = self.lineWaiter {
                self.lineWaiter = nil
                waiter()
            } else if !complete, error == nil {
                self.watchForCancel(token)
            }
        }
    }

    /// Cancelled on the PC: it deleted what arrived, so nothing continues.
    private func cancelledOnPC() {
        let name = activeIndex.map { files[$0].name } ?? ""
        DiagnosticLog.note("send: \(name) cancelled on the PC")
        stopConnection()
        BackgroundSend.shared.finish(success: false)
        try? journalBatch?.discard()
        journalBatch = nil
        DispatchQueue.main.async { self.pendingCount = 0 }
        publish(.cancelled, message: "Cancelled on \(destination?.name ?? "the PC"). Items already sent stay there.")
    }

    private func armTimeout(_ token: UUID, seconds: Double = 30) {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.link != nil else { return }
            self.fail("The PC stopped responding. Retry unsent files.")
        }
        timer = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func stopConnection() {
        generation = UUID()
        timer?.cancel(); timer = nil
        link?.cancel(); link = nil
        reader = nil
        activeIndex = nil
        buffer = Data()
        awaitingReceipt = false
        bodyHash = nil
        unread = 0
        inFlight = 0
        fileStartedAt = nil
        watching = false
        lineWaiter = nil
    }

    private func checkRevocation() -> Bool {
        guard journalBatch?.isRevoked == true else { return true }
        cleanUp(discard: true)
        publish(.failed, message: "This transfer was removed when its PC was forgotten.")
        return false
    }

    private func cleanUp(discard: Bool = false) {
        stopConnection()
        if discard || (manifest?.pendingCount ?? 0) == 0 { try? journalBatch?.discard() }
        journalBatch = nil
        manifest = nil
        files = []
        batch = []
        onSaved = nil
        destination = nil
        protocolVersion = nil
    }

    private func fail(_ text: String) {
        let uncertain = awaitingReceipt && !resumable
        let wasSending = link != nil
        stopConnection()
        BackgroundSend.shared.finish(success: false)
        if wasSending, !files.allSatisfy(\.sent) { announcePaused() }
        if !files.isEmpty, files.allSatisfy(\.sent) {
            publish(.sent, progress: 1, message: "All files were saved on your PC. The transfer connection closed.")
        } else {
            publish(.failed, message: uncertain ? "\(text) The last file may have been saved. Check the PC before retrying." : text)
        }
    }

    private func publish(_ phase: Phase, progress: Double? = nil, message: String) {
        let files = files
        let activeID = activeIndex.flatMap { files.indices.contains($0) ? files[$0].id : nil }
        let activeFraction = activeIndex.flatMap { files.indices.contains($0) && files[$0].bytes > 0
            ? Double(activeDone) / Double(files[$0].bytes) : nil } ?? 0
        let sent = doneBytes + activeDone
        let total = batchBytes > 0 ? batchBytes : files.filter { !$0.sent }.reduce(0) { $0 + $1.bytes }
        let left = phase == .sending ? smoothedLeft : nil
        DispatchQueue.main.async {
            self.items = files; self.phase = phase; self.message = message
            if let progress { self.progress = progress }
            else if phase == .preparing || phase == .ready || phase == .idle { self.progress = 0 }
            self.activeItemID = phase == .sending ? activeID : nil
            self.activeFraction = activeFraction
            self.sentBytes = phase == .sending || phase == .sent ? sent : 0
            self.totalBytes = total
            self.secondsLeft = left
        }
    }

    /// Time left from the speed since sending (or resuming) began, smoothed
    /// so the estimate doesn't jump about.
    private func measureRate(_ now: DispatchTime) {
        let sent = doneBytes + activeDone
        guard let base = rateBase else { rateBase = (now, sent); return }
        let seconds = Double(now.uptimeNanoseconds - base.at.uptimeNanoseconds) / 1e9
        guard seconds >= 2, sent > base.bytes else { return }
        let speed = Double(sent - base.bytes) / seconds
        let left = Double(batchBytes - sent) / speed
        smoothedLeft = smoothedLeft.map { $0 * 0.8 + left * 0.2 } ?? left
    }

    private static func reader(for file: Item) throws -> TransferBodyReader {
        switch file.source {
        case .staged: return try FileBodyReader(url: file.url)
        case .file(let bookmark): return try FileBodyReader(bookmark: bookmark)
        case .photo(let asset, let resource): return try PhotoBodyReader(asset: asset, resource: resource)
        }
    }

    /// iOS stopped the background work: pause, ready to continue.
    private func pauseForBackground() {
        queue.async {
            guard self.link != nil else { return }
            self.stopConnection()
            self.publish(.failed, message: "")
            Self.notify(about: self.files.first(where: { !$0.sent })) { SendNotice.stopped(thumbnail: $0) }
        }
    }

    private func announceSent() {
        BackgroundSend.shared.finish(success: true)
        guard !BackgroundSend.appInForeground,
              let first = batch.first.flatMap({ files.indices.contains($0) ? files[$0] : nil }) ?? files.first else { return }
        let pc = destination?.name ?? "your PC"
        let more = max(0, batch.count - 1)
        Self.notify(about: first) { SendNotice.sent(to: pc, first: first.name, more: more, thumbnail: $0) }
    }

    private func announcePaused() {
        guard !BackgroundSend.appInForeground else { return }
        let pc = destination?.name ?? "Your PC"
        Self.notify(about: files.first(where: { !$0.sent })) { SendNotice.paused(pc: pc, thumbnail: $0) }
    }

    /// Posts with the item's thumbnail, made off the sending queue.
    private static func notify(about item: Item?, _ post: @escaping (URL?) -> Void) {
        Task {
            var thumbnail: URL?
            if let item { thumbnail = await TransferThumbnail.attachmentFile(for: item.source, url: item.url) }
            post(thumbnail)
        }
    }

    private enum SendError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    private final class PreparationCancellation {
        private let lock = NSLock()
        private var id = UUID()

        func begin() -> UUID {
            lock.lock(); defer { lock.unlock() }
            id = UUID()
            return id
        }

        func cancel() { _ = begin() }

        func isCancelled(_ attempt: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return id != attempt
        }
    }
}
