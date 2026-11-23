import Foundation

/// Optional fields keep activity saved by older app versions readable.
struct ActivityRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String
    var detail: String
    var isFile: Bool
    var incoming: Bool
    var path: String? = nil
    var receivedFile: ReceivedFileReference? = nil
    var clipboardText: String? = nil
    var clipboardImage: String? = nil
    var bytes: Int64? = nil
    var isUnread: Bool? = nil

    var isReceivedFile: Bool { isFile && incoming }
    var isUnreadReceivedFile: Bool { isReceivedFile && isUnread == true }

    var fileReference: ReceivedFileReference? {
        if let receivedFile { return receivedFile }
        guard incoming, let path else { return nil }
        return ReceivedFileReference(id: id, name: path)
    }
}

/// History is independent of received files. Removing a record only removes
/// clipboard payloads owned by this store, never a user's received document.
final class ActivityHistoryStore {
    private struct Archive: Codable {
        let records: [ActivityRecord]
        let pendingIncomingImports: Set<UUID>
    }

    static let limit = 100
    private static let clipboardBudget = 16 * 1024 * 1024
    static func retained(_ records: [ActivityRecord]) -> [ActivityRecord] {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        var clipboardCount = 0
        return records.filter { item in
            if item.isFile { return true }
            if item.date < cutoff { return false }
            clipboardCount += 1
            return clipboardCount <= limit
        }
    }
    private let root: URL
    private let defaults: UserDefaults
    private let manager = FileManager.default
    private let legacyKey = "porthole.activity"
    // Retained until the transfer store acknowledges the import. This covers
    // interrupted writes even if the user has since removed the Activity row.
    private var pendingIncomingImports = Set<UUID>()

    init(root: URL, defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
    }

    func load() throws -> [ActivityRecord] {
        let file = root.appendingPathComponent("activity.json")
        if manager.fileExists(atPath: file.path) {
            try prepareDirectory()
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            let records: [ActivityRecord]
            if let archive = try? decoder.decode(Archive.self, from: data) {
                records = archive.records
                pendingIncomingImports = archive.pendingIncomingImports
            } else {
                records = try decoder.decode([ActivityRecord].self, from: data)
                pendingIncomingImports = []
            }
            let retained = retainedRecords(records)
            if retained.count == records.count { cleanOrphanImages(keeping: records) }
            else { try save(retained) }
            return retained
        }
        guard let legacy = defaults.data(forKey: legacyKey) else {
            cleanOrphanImages(keeping: [])
            return []
        }
        let records = try JSONDecoder().decode([ActivityRecord].self, from: legacy)
        let retained = retainedRecords(records)
        try save(retained)
        defaults.removeObject(forKey: legacyKey)
        return retained
    }

    @discardableResult
    func save(_ records: [ActivityRecord]) throws -> [ActivityRecord] {
        try prepareDirectory()
        let kept = retainedRecords(records)
        let archive = Archive(records: kept, pendingIncomingImports: pendingIncomingImports)
        try JSONEncoder().encode(archive).write(to: root.appendingPathComponent("activity.json"), options: writeOptions)
        cleanOrphanImages(keeping: kept)
        return kept
    }

    func importReceived(_ record: ActivityRecord, into records: [ActivityRecord]) throws -> [ActivityRecord] {
        guard pendingIncomingImports.insert(record.id).inserted else { return records }
        do {
            let updated = records.contains { $0.id == record.id } ? records
                : (records + [record]).sorted { $0.date > $1.date }
            return try save(updated)
        } catch {
            pendingIncomingImports.remove(record.id)
            throw error
        }
    }

    func completeIncomingImport(_ id: UUID) {
        pendingIncomingImports.remove(id)
    }

    private func retainedRecords(_ records: [ActivityRecord]) -> [ActivityRecord] {
        var remaining = Self.clipboardBudget
        var keptImages = Set<String>()
        return Self.retained(records).filter { record in
            guard !record.isFile else { return true }
            var size = record.clipboardText?.utf8.count ?? 0
            if let name = record.clipboardImage, !keptImages.contains(name) {
                guard let url = clipboardImageURL(name),
                      let imageSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      (1...Self.clipboardBudget).contains(imageSize) else { return false }
                size += imageSize
            }
            guard size <= remaining else { return false }
            remaining -= size
            if let name = record.clipboardImage { keptImages.insert(name) }
            return true
        }
    }

    private func cleanOrphanImages(keeping records: [ActivityRecord]) {
        let referenced = Set(records.compactMap(\.clipboardImage))
        for file in imageFiles() {
            if !referenced.contains(file.lastPathComponent) { try? manager.removeItem(at: file) }
        }
    }

    private var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return .atomic
        #endif
    }

    private func prepareDirectory() throws {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #endif
    }

    private func imageFiles() -> [URL] {
        let files = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])) ?? []
        return files.filter { file in
            file.pathExtension == "png" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil &&
                (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func clear() throws {
        try save([])
        defaults.removeObject(forKey: legacyKey)
    }

    func saveClipboardImage(_ data: Data, record original: ActivityRecord,
                            before existing: [ActivityRecord]) throws -> [ActivityRecord] {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try prepareDirectory()
        var record = original
        let name = UUID().uuidString + ".png"
        let file = root.appendingPathComponent(name)
        record.clipboardImage = name
        try data.write(to: file, options: writeOptions)
        do {
            // Commit the newer record first. save removes only the image
            // payloads excluded from the newly committed history.
            return try save([record] + existing)
        } catch {
            try? manager.removeItem(at: file)
            throw error
        }
    }

    func clipboardImageURL(_ name: String) -> URL? {
        guard name == (name as NSString).lastPathComponent,
              (name as NSString).pathExtension == "png",
              UUID(uuidString: (name as NSString).deletingPathExtension) != nil else { return nil }
        let url = root.appendingPathComponent(name)
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? url : nil
    }
}
