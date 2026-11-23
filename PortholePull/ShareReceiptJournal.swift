import Foundation

struct ShareReceipt: Codable, Equatable {
    var id: UUID
    var date: Date
    var peerName: String
    var name: String
    var bytes: Int64
    var pairingID: UUID? = nil
}

/// One atomic file per acknowledged share lets multiple extension invocations
/// enqueue independently. Imported receipts also reconcile re-selected pending items.
struct ShareReceiptJournal {
    private let root: URL
    private let manager = FileManager.default

    init(containerURL: URL) {
        root = containerURL.appendingPathComponent("ShareReceipts", isDirectory: true)
    }

    #if os(iOS)
    static func shared() -> Self? { TrustedPeerStore.containerURL.map { Self(containerURL: $0) } }
    #endif

    func record(_ receipt: ShareReceipt) throws {
        if acknowledged(receipt.id, pairingID: receipt.pairingID) { return }
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= 4096 else { throw CocoaError(.fileWriteUnknown) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try data.write(to: file(receipt.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file(receipt.id), options: .atomic)
        #endif
    }

    func pending() throws -> [ShareReceipt] {
        guard manager.fileExists(atPath: root.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)).compactMap { url in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let size = values.fileSize, (1...4096).contains(size),
                  let data = try? Data(contentsOf: url), data.count <= 4096,
                  let receipt = try? JSONDecoder().decode(ShareReceipt.self, from: data), receipt.id == id,
                  receipt.bytes > 0, !receipt.name.isEmpty else { return nil }
            return receipt
        }.sorted { $0.date < $1.date }
    }

    func acknowledged(_ id: UUID, pairingID: UUID?) -> Bool {
        for url in [file(id), imported(id)] {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4097), data.count <= 4096,
                  let receipt = try? JSONDecoder().decode(ShareReceipt.self, from: data),
                  receipt.id == id, receipt.pairingID == pairingID else { continue }
            return true
        }
        return false
    }

    func markImported(_ id: UUID) throws {
        let source = file(id)
        if manager.fileExists(atPath: imported(id).path) {
            try remove(id)
        } else if manager.fileExists(atPath: source.path) {
            try manager.moveItem(at: source, to: imported(id))
        }
    }

    func pruneImported() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for url in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? [] {
            guard url.pathExtension == "imported",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? manager.removeItem(at: url)
        }
    }

    func remove(_ id: UUID) throws {
        let url = file(id)
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
    }

    private func file(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    private func imported(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".imported") }
}
