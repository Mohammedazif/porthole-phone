import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct OutboundTransferManifest: Codable {
    struct File: Codable, Identifiable {
        let id: UUID
        let name: String
        let bytes: Int64
        let digest: String
        var sent: Bool
        var generatedName: Bool? = nil
        /// Where the bytes are read from; none means a copy in this batch.
        var source: TransferSource? = nil

        var isStaged: Bool { source?.isStaged ?? true }
    }

    let id: UUID
    let destination: TrustedPeer
    var files: [File]
    var version: Int? = nil

    var pendingCount: Int { files.filter { !$0.sent }.count }
}

/// The app and Share extension retain a review and its file IDs through a
/// process restart. The lock gives each batch one owner until its review closes.
struct OutboundTransferJournal {
    private struct Allocation: Codable {
        let pairingID: UUID
        let fingerprint: String
        var bytes: Int64

        func belongs(to peer: TrustedPeer) -> Bool {
            pairingID == peer.stableID && fingerprint == peer.fingerprint
        }
    }

    final class Batch {
        let folder: URL
        let id: UUID
        private let handle: FileHandle
        private let journal: OutboundTransferJournal

        fileprivate init?(folder: URL, id: UUID, journal: OutboundTransferJournal) {
            guard let fd = journal.lockBatch(folder) else { return nil }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.folder = folder
            self.id = id
            self.journal = journal
        }

        deinit {
            try? handle.close()
            if isRevoked { journal.removeRevoked(folder) }
        }

        var isRevoked: Bool { journal.isRevoked(folder) }

        func reserve(_ bytes: Int64) throws {
            try journal.reserve(bytes, in: folder)
        }

        func itemURL(named name: String, index: Int) -> URL {
            folder.appendingPathComponent(String(index), isDirectory: true).appendingPathComponent(name)
        }

        func load() -> OutboundTransferManifest? {
            guard !isRevoked else { return nil }
            guard var manifest = journal.manifest(in: folder, id: id) else { return nil }
            journal.applyReceipts(to: &manifest)
            return manifest
        }

        /// Preserve the pending item identity, including after the desktop has
        /// committed the file and its reply was lost. Staging stays in this batch.
        func saveSelection(_ selection: OutboundTransferManifest, version: Int) throws -> OutboundTransferManifest {
            var selection = selection
            var pending = try journal.pendingFiles(for: selection.destination, version: version, excluding: id)
            for index in selection.files.indices {
                let file = selection.files[index]
                guard let match = pending.firstIndex(where: { previous in
                    previous.bytes == file.bytes && previous.digest == file.digest &&
                    (previous.name == file.name || (file.generatedName == true &&
                        (previous.generatedName == true || previous.name.range(
                            of: #"^File-[0-9]{8}-[0-9]{6}-[0-9]+\."#, options: .regularExpression) != nil)))
                }) else { continue }
                var previous = pending.remove(at: match)
                if file.name != previous.name, file.isStaged {
                    try FileManager.default.moveItem(at: itemURL(named: file.name, index: index),
                                                     to: itemURL(named: previous.name, index: index))
                }
                previous.source = file.source // read from where it is now
                selection.files[index] = previous
                selection.version = version
            }
            try save(selection)
            return selection
        }

        func save(_ manifest: OutboundTransferManifest) throws {
            guard !isRevoked else { throw TransferStaging.Failure.cancelled }
            guard manifest.id == id, manifest.destination.channelTicket == nil else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            if let allocation = journal.allocation(in: folder) {
                var available = allocation.bytes
                // Only Porthole's own copies take space; originals stay where they are.
                guard allocation.belongs(to: manifest.destination), manifest.files.allSatisfy({ file in
                    guard file.bytes > 0 else { return false }
                    guard file.isStaged else { return true }
                    guard file.bytes <= available else { return false }
                    available -= file.bytes
                    return true
                }) else { throw TransferStaging.Failure.sharedBudget }
            }
            try journal.write(manifest, to: folder.appendingPathComponent("batch.json"))
        }

        func record(_ receipt: ShareReceipt) throws {
            try journal.receipts.record(receipt)
        }

        func discard() throws { try FileManager.default.removeItem(at: folder) }
    }

    private let directory: URL
    private let manager = FileManager.default
    private let totalBudget = TransferStaging.maxBatchBytes
    private var receipts: ShareReceiptJournal { ShareReceiptJournal(containerURL: directory.deletingLastPathComponent()) }

    init(container: URL) {
        directory = container.appendingPathComponent("Pending outbound transfers", isDirectory: true)
    }

    static func shared() -> Self? { PortholeAppGroup.containerURL.map(Self.init(container:)) }

    func makeBatch(for peer: TrustedPeer) throws -> Batch {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        #endif
        return try withCatalog {
            try reclaim()
            guard try batches().count < 8 else { throw CocoaError(.fileWriteOutOfSpace) }
            let id = UUID()
            let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                try write(Allocation(pairingID: peer.stableID, fingerprint: peer.fingerprint, bytes: 0),
                          to: allocationURL(folder))
                guard let batch = Batch(folder: folder, id: id, journal: self) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return batch
            } catch {
                try? manager.removeItem(at: folder)
                throw error
            }
        }
    }

    func openPending(for peer: TrustedPeer) -> (Batch, OutboundTransferManifest)? {
        try? withCatalog {
            let available = try batches().sorted { modified(at: $0.1) > modified(at: $1.1) }
            for (id, url) in available where !expired(url) && !isRevoked(url) {
                guard let batch = Batch(folder: url, id: id, journal: self), let manifest = batch.load(),
                      manifest.pendingCount > 0, manifest.destination.samePairing(as: peer) else { continue }
                return (batch, manifest)
            }
            return nil
        }
    }

    private func applyReceipts(to manifest: inout OutboundTransferManifest) {
        let peer = manifest.destination.stableID
        for index in manifest.files.indices where !manifest.files[index].sent {
            if receipts.acknowledged(manifest.files[index].id, pairingID: peer) {
                manifest.files[index].sent = true
            }
        }
    }

    private func pendingFiles(for peer: TrustedPeer, version: Int,
                              excluding current: UUID) throws -> [OutboundTransferManifest.File] {
        try withCatalog {
            var pending: [OutboundTransferManifest.File] = []
            var seen = Set<UUID>()
            for (id, url) in try batches().sorted(by: { modified(at: $0.1) > modified(at: $1.1) })
                where id != current && !expired(url) && !isRevoked(url) {
                guard var prior = manifest(in: url, id: id), prior.destination.samePairing(as: peer),
                      prior.version == nil || prior.version == version else { continue }
                applyReceipts(to: &prior)
                for file in prior.files where !file.sent && seen.insert(file.id).inserted {
                    pending.append(file)
                }
            }
            return pending
        }
    }

    func discard(for peer: TrustedPeer) {
        try? withCatalog {
            for (id, url) in try batches() {
                let belongs = allocation(in: url)?.belongs(to: peer)
                    ?? (manifest(in: url, id: id)?.destination.samePairing(as: peer) == true)
                guard belongs else { continue }
                // Install the marker before looking for the lease. A holder
                // releasing concurrently checks the marker after unlocking.
                try? Data().write(to: revokedURL(url), options: writeOptions)
                removeRevoked(url)
            }
        }
    }

    func reclaimExpired() {
        try? withCatalog { try reclaim() }
    }

    private func reclaim() throws {
        for (id, url) in try batches() {
            guard let batch = Batch(folder: url, id: id, journal: self) else { continue }
            let manifestExists = manager.fileExists(atPath: url.appendingPathComponent("batch.json").path)
            if isRevoked(url) || !manifestExists || expired(url) || batch.load()?.pendingCount == 0 {
                try? batch.discard()
            }
        }
    }

    private func lockBatch(_ folder: URL) -> Int32? {
        let lock = folder.appendingPathComponent("lock")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }

    private func removeRevoked(_ folder: URL) {
        guard let fd = lockBatch(folder) else { return }
        defer { close(fd) }
        if isRevoked(folder) { try? manager.removeItem(at: folder) }
    }

    private func reserve(_ bytes: Int64, in folder: URL) throws {
        guard bytes > 0, bytes <= TransferStaging.maxFileBytes else { throw TransferStaging.Failure.invalidFile }
        try withCatalog {
            guard !isRevoked(folder), var current = allocation(in: folder) else {
                throw TransferStaging.Failure.cancelled
            }
            var available = totalBudget
            for (id, url) in try batches() {
                if let reserved = allocation(in: url) {
                    available -= reserved.bytes
                } else if let old = manifest(in: url, id: id) {
                    for file in old.files where file.isStaged { available -= min(file.bytes, totalBudget) }
                }
                if available < bytes { throw TransferStaging.Failure.sharedBudget }
            }
            current.bytes += bytes
            try write(current, to: allocationURL(folder))
        }
    }

    private func withCatalog<T>(_ action: () throws -> T) throws -> T {
        let catalog = directory.appendingPathComponent("catalog.lock")
        let fd = open(catalog.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        let deadline = DispatchTime.now() + .milliseconds(200)
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return try action() }
            guard errno == EWOULDBLOCK || errno == EINTR else { break }
            usleep(10_000)
        } while DispatchTime.now() < deadline
        throw CocoaError(.fileWriteUnknown)
    }

    private func allocationURL(_ folder: URL) -> URL { folder.appendingPathComponent("allocation.json") }
    private func revokedURL(_ folder: URL) -> URL { folder.appendingPathComponent("revoked") }

    private func isRevoked(_ folder: URL) -> Bool {
        manager.fileExists(atPath: revokedURL(folder).path)
    }

    private func allocation(in folder: URL) -> Allocation? {
        guard let allocation: Allocation = read(allocationURL(folder), limit: 4096),
              (0...totalBudget).contains(allocation.bytes) else { return nil }
        return allocation
    }

    private func manifest(in folder: URL, id: UUID) -> OutboundTransferManifest? {
        guard let batch: OutboundTransferManifest = read(folder.appendingPathComponent("batch.json"), limit: 512 * 1024),
              batch.id == id, batch.destination.channelTicket == nil,
              !batch.files.isEmpty, batch.files.count <= TransferStaging.maxItems,
              Set(batch.files.map(\.id)).count == batch.files.count,
              batch.version.map({ $0 == 2 || $0 == 3 }) ?? true,
              batch.files.allSatisfy({
                  !$0.name.isEmpty && !$0.name.hasPrefix(".") && $0.name.utf8.count <= 200 &&
                  !$0.name.contains("/") && !$0.name.contains("\\") && !$0.name.contains(":") &&
                  !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
                  $0.bytes > 0 && TrustedPeer.isChannelTicket($0.digest)
              }) else { return nil }
        return batch
    }

    private func read<Value: Decodable>(_ url: URL, limit: Int) -> Value? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return .atomic
        #endif
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: writeOptions)
    }

    private func expired(_ url: URL) -> Bool {
        modified(at: url) < Date().addingTimeInterval(-7 * 86_400)
    }

    private func batches() throws -> [(UUID, URL)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let info = try? url.resourceValues(forKeys: Set(keys)),
                  info.isDirectory == true, info.isSymbolicLink != true else { return nil }
            return (id, url)
        }
    }

    private func modified(at url: URL) -> Date {
        let manifest = url.appendingPathComponent("batch.json")
        let file = manager.fileExists(atPath: manifest.path) ? manifest : url
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
