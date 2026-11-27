import Foundation

struct IncomingTransfer: Codable, Equatable {
    let id: String
    let digest: String
    let bytes: Int
    let name: String

    init?(header: String) {
        let fields = header.split(separator: " ", maxSplits: 4).map(String.init)
        guard fields.count == 5, fields[0] == "PUSH2" || fields[0] == "PUSH3", fields[1].utf8.count == 32,
              fields[1].utf8.allSatisfy(Self.isHex), fields[2].utf8.count == 64,
              fields[2].utf8.allSatisfy(Self.isHex),
              let bytes = Int(fields[3]), (1...Int(TransferStaging.maxFileBytes)).contains(bytes),
              fields[4].utf8.count <= 200, ReceivedFileWriter.validName(fields[4]) else { return nil }
        id = fields[1]
        digest = fields[2]
        self.bytes = bytes
        name = fields[4]
    }

    static func chunkLength(_ header: String, remaining: Int) -> Int? {
        let fields = header.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "CHUNK",
              fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(fields[1]), length > 0, length <= min(65_536, remaining) else { return nil }
        return length
    }

    fileprivate static func isHex(_ value: UInt8) -> Bool { (48...57).contains(value) || (97...102).contains(value) }
}

struct IncomingTransferStore {
    let root: URL
    private let manager = FileManager.default

    struct Stage {
        let data: URL
        let receipt: URL
        let handle: FileHandle
        let offset: Int
    }

    struct Receipt: Codable {
        let reference: ReceivedFileReference
        let device: String
        let date: Date
    }

    enum State {
        case staged(Stage)
        case saved(Receipt?, at: URL)
    }

    /// Must be called on the storage queue. A profile separates IDs from different PCs.
    func prepare(_ transfer: IncomingTransfer, profile: String) throws -> State {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        #endif
        guard profile.utf8.count == 64, profile.utf8.allSatisfy(IncomingTransfer.isHex) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let directory = root.appendingPathComponent(profile + "-" + transfer.id, isDirectory: true)
        let manifest = directory.appendingPathComponent("manifest.json")
        let receipt = directory.appendingPathComponent("saved.json")
        let partial = directory.appendingPathComponent("body")
        let (reserved, count) = try reclaim(skipping: directory)
        if manager.fileExists(atPath: directory.path) {
            guard loadManifest(manifest) == transfer else { throw CocoaError(.fileReadCorruptFile) }
            if manager.fileExists(atPath: receipt.path) {
                let data = try readJournal(receipt)
                let committed = try? JSONDecoder().decode(Receipt.self, from: data)
                if committed == nil { _ = try JSONDecoder().decode(ReceivedFileReference.self, from: data) }
                try? manager.removeItem(at: partial)
                let pending = manager.fileExists(atPath: importedMarker(for: receipt).path) ? nil : committed
                return .saved(pending, at: receipt)
            }
        } else {
            // Any size, as long as this iPhone has room for it and the other
            // unfinished files (plus a little to spare).
            let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            guard count < 64,
                  free.map({ reserved + Int64(transfer.bytes) + 256 * 1024 * 1024 <= $0 }) ?? true else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            do { try JSONEncoder().encode(transfer).write(to: manifest, options: protectedWrite) }
            catch { try? manager.removeItem(at: directory); throw error }
        }
        if !manager.fileExists(atPath: partial.path) {
            #if os(iOS)
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            #else
            let attributes: [FileAttributeKey: Any] = [:]
            #endif
            guard manager.createFile(atPath: partial.path, contents: nil, attributes: attributes) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            let offset = try handle.seekToEnd()
            guard offset <= UInt64(transfer.bytes) else { throw CocoaError(.fileReadCorruptFile) }
            return .staged(Stage(data: partial, receipt: receipt, handle: handle, offset: Int(offset)))
        } catch { try? handle.close(); throw error }
    }

    func reclaimExpired() {
        guard manager.fileExists(atPath: root.path) else { return }
        _ = try? reclaim(skipping: nil)
    }

    private var stagingDirectory: URL {
        root.appendingPathComponent("Destination staging", isDirectory: true)
    }

    func planStaging(_ intent: ReceivedFileStorage.StagingIntent) throws {
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let file = stagingDirectory.appendingPathComponent(intent.id.uuidString + ".json")
        try JSONEncoder().encode(intent).write(to: file, options: protectedWrite)
    }

    func completeStaging(_ id: UUID) {
        let file = stagingDirectory.appendingPathComponent(id.uuidString + ".json")
        try? manager.removeItem(at: file)
    }

    func pendingStaging() -> [ReceivedFileStorage.StagingIntent] {
        let files = (try? manager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? readJournal(url),
                  let intent = try? JSONDecoder().decode(ReceivedFileStorage.StagingIntent.self, from: data),
                  intent.id == id else { return nil }
            return intent
        }
    }

    private func transferDirectories() throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)).filter { candidate in
            let parts = candidate.lastPathComponent.split(separator: "-")
            guard parts.count == 2, parts[0].utf8.count == 64, parts[1].utf8.count == 32,
                  parts.allSatisfy({ $0.utf8.allSatisfy(IncomingTransfer.isHex) }),
                  let info = try? candidate.resourceValues(forKeys: keys) else { return false }
            return info.isDirectory == true && info.isSymbolicLink != true
        }
    }

    private func reclaim(skipping active: URL?) throws -> (Int64, Int) {
        let now = Date()
        var reserved: Int64 = 0
        var count = 0
        for candidate in try transferDirectories() where candidate != active {
            let receipt = candidate.appendingPathComponent("saved.json")
            let saved = manager.fileExists(atPath: receipt.path)
            let recentFile = saved ? receipt : candidate.appendingPathComponent("body")
            let updated = modified(recentFile)
            let imported = saved ? modified(importedMarker(for: receipt)) : nil
            let newest = imported.map { max($0, updated ?? .distantPast) } ?? updated
            let canExpire: Bool
            if saved, !manager.fileExists(atPath: importedMarker(for: receipt).path) {
                // Old versions saved only the file reference and already updated
                // history. A current receipt may still need to be imported.
                canExpire = (try? JSONDecoder().decode(ReceivedFileReference.self, from: readJournal(receipt))) != nil
            } else {
                canExpire = true
            }
            if canExpire,
               let change = newest ?? modified(candidate),
               change < now.addingTimeInterval(saved ? -7 * 86400 : -86400) {
                try? manager.removeItem(at: candidate)
                if !manager.fileExists(atPath: candidate.path) { continue }
            }
            if !saved, let existing = loadManifest(candidate.appendingPathComponent("manifest.json")),
               (1...Int(TransferStaging.maxFileBytes)).contains(existing.bytes) {
                reserved += Int64(existing.bytes)
                count += 1
            }
        }
        return (reserved, count)
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func intent(for stage: Stage) -> ReceivedFileStorage.PublicationIntent? {
        let url = stage.receipt.deletingLastPathComponent().appendingPathComponent("intent.json")
        guard let data = try? readJournal(url) else { return nil }
        return try? JSONDecoder().decode(ReceivedFileStorage.PublicationIntent.self, from: data)
    }

    func plan(_ intent: ReceivedFileStorage.PublicationIntent, at stage: Stage) throws {
        let url = stage.receipt.deletingLastPathComponent().appendingPathComponent("intent.json")
        try JSONEncoder().encode(intent).write(to: url, options: protectedWrite)
    }

    func record(_ file: ReceivedFileReference, from device: String, at url: URL) throws -> Receipt {
        let receipt = Receipt(reference: file, device: device, date: Date())
        try JSONEncoder().encode(receipt).write(to: url, options: protectedWrite)
        return receipt
    }

    private func readJournal(_ url: URL) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try Data(contentsOf: url)
    }

    private func importedMarker(for receipt: URL) -> URL {
        receipt.deletingLastPathComponent().appendingPathComponent("imported")
    }

    func markImported(_ receipt: URL) throws {
        try Data().write(to: importedMarker(for: receipt), options: protectedWrite)
    }

    func unimportedReceipts() -> [(URL, Receipt)] {
        ((try? transferDirectories()) ?? []).compactMap { directory in
            let url = directory.appendingPathComponent("saved.json")
            guard !manager.fileExists(atPath: importedMarker(for: url).path),
                  let data = try? readJournal(url), let receipt = try? JSONDecoder().decode(Receipt.self, from: data)
            else { return nil }
            return (url, receipt)
        }
    }

    private var protectedWrite: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return .atomic
        #endif
    }

    private func loadManifest(_ url: URL) -> IncomingTransfer? {
        guard let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(IncomingTransfer.self, from: data)
    }
}
