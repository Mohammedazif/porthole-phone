import Foundation
import Network
import Combine

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
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [Item] = []
    @Published private(set) var progress: Double = 0
    @Published private(set) var message = ""
    @Published private(set) var pendingCount = 0
    private let queue = DispatchQueue(label: "porthole.sendFiles")
    private let preparation = PreparationCancellation()
    private var generation = UUID()
    private var files: [Item] = []
    private var journalBatch: OutboundTransferJournal.Batch?
    private var manifest: OutboundTransferManifest?
    private var link: NWConnection?
    private var handle: FileHandle?
    private var buffer = Data()
    private var timer: DispatchWorkItem?
    private var batch: [Int] = []
    private var destination: TrustedPeer?
    private var verifiedPeer: TrustedPeer?
    private var protocolVersion: Int?
    private var resumable: Bool { (protocolVersion ?? 1) >= 2 }
    private var awaitingReceipt = false
    private var lastProgressAt = DispatchTime.now()
    private var onSaved: (() -> Void)?

    func prepare(_ urls: [URL], for peer: TrustedPeer) {
        let attempt = preparation.begin()
        queue.async {
            self.cleanUp()
            self.publish(.preparing, message: "Preparing selected files…")
            do {
                guard !urls.isEmpty else { throw SendError.message("No files selected.") }
                guard urls.count <= TransferStaging.maxItems else { throw SendError.message("Send up to 500 files at a time.") }
                let journal = OutboundTransferJournal(container: PortholeAppGroup.containerURL ?? Self.privateContainer)
                let batch = try journal.makeBatch(for: peer)
                self.journalBatch = batch
                self.destination = peer.remembered
                let folder = batch.folder
                let manager = FileManager.default
                var remaining = TransferStaging.maxBatchBytes
                for (index, url) in urls.enumerated() {
                    if self.preparation.isCancelled(attempt) { throw TransferStaging.Failure.cancelled }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let name = TransferFileName.make(url.lastPathComponent, index: index)
                    let directory = folder.appendingPathComponent(String(index), isDirectory: true)
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                    let target = directory.appendingPathComponent(name)
                    var coordinatorError: NSError?
                    var staged: Result<(bytes: Int64, digest: String), Error>?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinated in
                        staged = Result {
                            try TransferStaging.snapshot(coordinated, to: target, remaining: remaining, reserve: batch.reserve) {
                                self.preparation.isCancelled(attempt) || batch.isRevoked
                            }
                        }
                    }
                    if let coordinatorError { throw coordinatorError }
                    guard let staged else { throw SendError.message("Unable to prepare \(name).") }
                    let snapshot = try staged.get()
                    remaining -= snapshot.bytes
                    self.files.append(Item(id: UUID(), url: target, name: name, bytes: snapshot.bytes, digest: snapshot.digest))
                }
                if self.preparation.isCancelled(attempt) { throw TransferStaging.Failure.cancelled }
                let manifest = OutboundTransferManifest(id: batch.id, destination: peer.remembered,
                                                        files: self.files.map { file in
                    .init(id: file.id, name: file.name, bytes: file.bytes, digest: file.digest, sent: false)
                })
                let reviewed = try batch.saveSelection(manifest, version: peer.receiveVersion)
                self.files = reviewed.files.enumerated().map { index, file in
                    Item(id: file.id, url: batch.itemURL(named: file.name, index: index), name: file.name,
                         bytes: file.bytes, digest: file.digest)
                }
                self.manifest = reviewed
                self.protocolVersion = reviewed.version
                self.publish(.ready, message: "Ready to send \(self.files.count) \(self.files.count == 1 ? "file" : "files").")
            } catch {
                self.cleanUp()
                if self.preparation.isCancelled(attempt) { self.publish(.cancelled, message: "File preparation cancelled.") }
                else { self.fail(error.localizedDescription) }
            }
        }
    }

    func refreshPending(for peer: TrustedPeer?) {
        queue.async {
            self.verifiedPeer = peer
            if self.link != nil, self.destination?.id != peer?.id {
                self.fail("The PC disconnected. Retry when it reconnects.")
            }
            let count = peer.flatMap { Self.pending(for: $0)?.1.pendingCount } ?? 0
            DispatchQueue.main.async { self.pendingCount = count }
        }
    }

    func restorePending(for peer: TrustedPeer) {
        queue.async {
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
                     bytes: file.bytes, digest: file.digest, sent: file.sent)
            }
            self.publish(.failed, message: "Review and retry the remaining files for \(peer.name).")
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
                            guard self.verifiedPeer?.id == current.id else {
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
        queue.async {
            guard self.link != nil || !self.files.isEmpty else { return }
            let uncertain = self.awaitingReceipt && !self.resumable
            self.stopConnection()
            if !self.files.isEmpty, self.files.allSatisfy(\.sent) {
                self.publish(.sent, progress: 1, message: "All files have already been saved on your PC.")
            } else if uncertain {
                self.publish(.cancelled, message: "Transfer cancelled while confirming a file. Check the PC before retrying that file.")
            } else {
                self.publish(.cancelled, message: "Transfer cancelled. Files already acknowledged by the PC remain sent.")
            }
        }
    }

    func reset() {
        preparation.cancel()
        queue.async { self.cleanUp(); self.publish(.idle, message: "") }
    }

    func discardPending() {
        queue.async {
            self.cleanUp(discard: true)
            self.publish(.idle, message: "")
        }
    }

    private func sendFile(_ cursor: Int, token: UUID) {
        guard generation == token, link != nil else { return }
        if cursor == batch.count {
            write(Data("DONE\n".utf8), token: token) {
                self.readLine(token: token) { line in
                    guard line == "BYE" else { self.fail("The PC did not confirm the transfer session."); return }
                    self.stopConnection()
                    self.publish(.sent, progress: 1, message: "Files sent to your PC.")
                }
            }
            return
        }
        let file = files[batch[cursor]]
        do { handle = try FileHandle(forReadingFrom: file.url) }
        catch { fail("Unable to read \(file.name)."); return }
        let ticket = file.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let header: String
        switch protocolVersion {
        case 3: header = "ITEM \(ticket) \(file.digest) \(file.bytes) \(file.name)\n"
        case 2: header = "ITEM \(ticket) FILE \(file.bytes) \(file.name)\n"
        default: header = "FILE \(file.bytes) \(file.name)\n"
        }
        write(Data(header.utf8), token: token) {
            if !self.resumable { self.pump(cursor, remaining: file.bytes, token: token); return }
            self.readLine(token: token) { response in
                if response == "SAVED" { self.accept(cursor, token: token); return }
                guard response.hasPrefix("OFFSET "), let offset = Int64(response.dropFirst(7)), (0...file.bytes).contains(offset) else {
                    self.fail("The PC could not resume this transfer."); return
                }
                do { try self.handle?.seek(toOffset: UInt64(offset)) }
                catch { self.fail("Unable to read the selected file."); return }
                self.pump(cursor, remaining: file.bytes - offset, token: token)
            }
        }
    }

    private func accept(_ cursor: Int, token: UUID) {
        awaitingReceipt = false
        try? handle?.close(); handle = nil
        let index = batch[cursor], file = files[index]
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
        publish(.sending, progress: Double(cursor + 1) / Double(batch.count), message: "Saved \(file.name) on your PC.")
        sendFile(cursor + 1, token: token)
    }

    private func pump(_ cursor: Int, remaining: Int64, token: UUID) {
        guard generation == token, link != nil else { return }
        let index = batch[cursor], file = files[index]
        if remaining == 0 {
            try? handle?.close(); handle = nil
            awaitingReceipt = true
            readLine(token: token) { line in
                guard line == "OK" else { self.fail("The PC did not save \(file.name). Reconnect and retry unsent files."); return }
                self.accept(cursor, token: token)
            }
            return
        }
        do {
            let data = try autoreleasepool { try handle?.read(upToCount: Int(min(remaining, 1 << 20))) }
            guard let data, !data.isEmpty else {
                fail("Unable to finish reading \(file.name)."); return
            }
            if Int64(data.count) == remaining { awaitingReceipt = true }
            write(data, token: token) {
                let left = remaining - Int64(data.count)
                let part = Double(file.bytes - left) / Double(file.bytes)
                let now = DispatchTime.now()
                if now.uptimeNanoseconds - self.lastProgressAt.uptimeNanoseconds >= 150_000_000 {
                    self.lastProgressAt = now
                    self.publish(.sending, progress: (Double(cursor) + part) / Double(self.batch.count), message: "Sending \(file.name)…")
                }
                self.pump(cursor, remaining: left, token: token)
            }
        } catch { fail("Unable to read \(file.name).") }
    }

    private func write(_ data: Data, token: UUID, then completion: @escaping () -> Void) {
        guard generation == token, let connection = link else { return }
        guard checkRevocation() else { return }
        guard verifiedPeer?.id == destination?.id else {
            fail("The PC disconnected. Retry when it reconnects.")
            return
        }
        armTimeout(token)
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, self.generation == token, self.link === connection else { return }
            if error != nil { self.fail("Connection lost during transfer. Retry unsent files.") }
            else { completion() }
        })
    }

    private func readLine(token: UUID, completion: @escaping (String) -> Void) {
        armTimeout(token)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self, weak connection] data, _, complete, error in
            guard let self, self.generation == token, self.link === connection else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if (complete || error != nil) && !self.buffer.contains(10) { self.fail("PC connection closed before confirmation.") }
            else { self.readLineFragment(token: token, completion: completion) }
        }
    }

    private func armTimeout(_ token: UUID) {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.link != nil else { return }
            self.fail("The PC stopped responding. Retry unsent files.")
        }
        timer = work
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func stopConnection() {
        generation = UUID()
        timer?.cancel(); timer = nil
        link?.cancel(); link = nil
        try? handle?.close(); handle = nil
        buffer = Data()
        awaitingReceipt = false
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
        stopConnection()
        if !files.isEmpty, files.allSatisfy(\.sent) {
            publish(.sent, progress: 1, message: "All files were saved on your PC. The transfer connection closed.")
        } else {
            publish(.failed, message: uncertain ? "\(text) The last file may have been saved. Check the PC before retrying." : text)
        }
    }

    private func publish(_ phase: Phase, progress: Double? = nil, message: String) {
        let files = files
        DispatchQueue.main.async {
            self.items = files; self.phase = phase; self.message = message
            if let progress { self.progress = progress }
            else if phase == .preparing || phase == .ready || phase == .idle { self.progress = 0 }
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
