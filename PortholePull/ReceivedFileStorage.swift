import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ReceivedFileReference: Codable, Equatable {
    var id = UUID()
    var name: String
    var folderName = "On My iPhone › Porthole"
    var folderBookmark: Data? = nil
    var bytes: Int64? = nil
    var identity: ReceivedFileIdentity? = nil
}

/// Local filesystem identity supplements the path in new receipts. Providers
/// can recycle names, so opening an old receipt must verify the observed file.
struct ReceivedFileIdentity: Codable, Equatable {
    let volume: UInt64?
    let number: UInt64?
    let created: Date?

    init?(attributes: [FileAttributeKey: Any]) {
        volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        created = attributes[.creationDate] as? Date
        if number == nil && created == nil { return nil }
    }
}

enum ReceivedStorageError: LocalizedError {
    case invalidName, folderUnavailable, fileUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidName: return "This file name is not supported."
        case .folderUnavailable: return "The save folder is unavailable. Choose it again in Settings."
        case .fileUnavailable: return "This file is unavailable. It may have been moved or deleted in Files."
        }
    }
}

/// Commits under a unique name without replacing existing files. Source data
/// survives every failed save, including a revoked external-folder permission.
enum ReceivedFileWriter {
    static func stagingFolder(_ id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(".porthole-\(id.uuidString).stage", isDirectory: true)
    }

    static func stagingMarker(_ token: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(".owner-\(token.uuidString)")
    }

    static func removeStagingFolder(_ folder: URL, token: UUID) throws {
        let manager = FileManager.default
        let values: [FileAttributeKey: Any]
        do { values = try manager.attributesOfItem(atPath: folder.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
        guard values[.type] as? FileAttributeType == .typeDirectory else { return }
        let owner = stagingMarker(token, in: folder)
        let marker: [FileAttributeKey: Any]?
        do { marker = try manager.attributesOfItem(atPath: owner.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            marker = nil
        }
        if marker?[.type] as? FileAttributeType == .typeRegular {
            let body = folder.appendingPathComponent("body")
            do {
                let attributes = try manager.attributesOfItem(atPath: body.path)
                if attributes[.type] as? FileAttributeType == .typeRegular {
                    try manager.removeItem(at: body)
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            }
            try manager.removeItem(at: owner)
        }
        // The marker is installed before copying. rmdir also covers an
        // interrupted empty reservation and leaves any unexpected contents.
        guard rmdir(folder.path) == 0 || errno == ENOENT || errno == ENOTEMPTY else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") &&
        !name.contains("/") && !name.contains("\\") && !name.contains(":") &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func save(_ source: URL, named name: String, in folder: URL,
                     willStage: ((UUID, UUID) throws -> Void)? = nil,
                     didRemoveStage: ((UUID) -> Void)? = nil,
                     willPublish: ((URL, URL) throws -> Void)? = nil) throws -> URL {
        guard validName(name) else { throw ReceivedStorageError.invalidName }
        let manager = FileManager.default
        let sourceAttributes = try manager.attributesOfItem(atPath: source.path)
        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw ReceivedStorageError.fileUnavailable
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderAttributes = try manager.attributesOfItem(atPath: folder.path)
        guard folderAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ReceivedStorageError.folderUnavailable
        }
        let stageID = UUID()
        let owner = UUID()
        let temporary = stagingFolder(stageID, in: folder)
        try willStage?(stageID, owner)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer {
            if (try? removeStagingFolder(temporary, token: owner)) != nil { didRemoveStage?(stageID) }
        }
        try Data().write(to: stagingMarker(owner, in: temporary), options: .withoutOverwriting)
        let staging = temporary.appendingPathComponent("body")
        try manager.copyItem(at: source, to: staging)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for number in 1...10_000 {
            let candidate = number == 1 ? name : ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let destination = folder.appendingPathComponent(candidate)
            if manager.fileExists(atPath: destination.path) { continue }
            try willPublish?(staging, destination)
            do {
                try manager.moveItem(at: staging, to: destination)
                return destination
            } catch {
                if (error as NSError).code == CocoaError.fileWriteFileExists.rawValue { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

final class ReceivedFileStorage {
    private struct Selection: Codable {
        var bookmark: Data
        var name: String
    }
    private let defaults: UserDefaults
    private let defaultFolder: URL
    private let previewFolder: URL
    private let lock = NSLock()
    private var cleanedPreviews = false
    private let preferenceKey = "porthole.receivedSaveFolder"

    init(defaultFolder: URL, previewFolder: URL, defaults: UserDefaults = .standard) {
        self.defaultFolder = defaultFolder
        self.previewFolder = previewFolder
        self.defaults = defaults
    }

    private func selection() -> Selection? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: preferenceKey) else { return nil }
        return try? JSONDecoder().decode(Selection.self, from: data)
    }

    var folderName: String { selection()?.name ?? "On My iPhone › Porthole" }
    var usesCustomFolder: Bool { selection() != nil }

    func resetFolder() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: preferenceKey)
    }

    #if os(iOS) || os(macOS)
    private func ownsDirectory(_ url: URL) -> Bool {
        let root = defaultFolder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    func chooseFolder(_ url: URL) throws {
        if url.standardizedFileURL == defaultFolder.standardizedFileURL { resetFolder(); return }
        let scoped = url.startAccessingSecurityScopedResource()
        guard scoped || ownsDirectory(url) else { throw ReceivedStorageError.folderUnavailable }
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ReceivedStorageError.folderUnavailable
        }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
        let prefix = url.path.contains("com~apple~CloudDocs") ? "iCloud Drive" : "Files"
        let data = try JSONEncoder().encode(Selection(bookmark: bookmark, name: "\(prefix) › \(name)"))
        lock.lock()
        defer { lock.unlock() }
        defaults.set(data, forKey: preferenceKey)
    }

    private func withFolder<T>(_ bookmark: Data, perform: (URL, Data) throws -> T) throws -> T {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        guard scoped || ownsDirectory(url) else { throw ReceivedStorageError.folderUnavailable }
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ReceivedStorageError.folderUnavailable
        }
        let fresh = stale ? try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) : bookmark
        if fresh != bookmark {
            lock.lock()
            if let data = defaults.data(forKey: preferenceKey),
               var current = try? JSONDecoder().decode(Selection.self, from: data), current.bookmark == bookmark {
                current.bookmark = fresh
                if let data = try? JSONEncoder().encode(current) { defaults.set(data, forKey: preferenceKey) }
            }
            lock.unlock()
        }
        return try perform(url, fresh)
    }
    #endif

    struct SavedFile {
        var reference: ReceivedFileReference
        var localURL: URL?
        var warning: String?
    }

    private struct ReceiptFailure: Error { let cause: Error }

    private func makeReference(_ url: URL, folderName: String = "On My iPhone › Porthole",
                               bookmark: Data? = nil) throws -> ReceivedFileReference {
        let values = try regularFileAttributes(url)
        return ReceivedFileReference(name: url.lastPathComponent, folderName: folderName, folderBookmark: bookmark,
                                     bytes: (values[.size] as? NSNumber)?.int64Value,
                                     identity: ReceivedFileIdentity(attributes: values))
    }

    private func regularFileAttributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              values[.type] as? FileAttributeType == .typeRegular else { throw ReceivedStorageError.fileUnavailable }
        return values
    }

    private func verify(_ file: ReceivedFileReference, at url: URL) throws {
        let values = try regularFileAttributes(url)
        if let identity = file.identity, ReceivedFileIdentity(attributes: values) != identity {
            throw ReceivedStorageError.fileUnavailable
        }
    }

    private func recordReference(_ reference: ReceivedFileReference, at url: URL,
                                 using record: (ReceivedFileReference) throws -> Void) throws {
        do { try record(reference) }
        catch {
            // Roll back only the receipt's own publication. A replacement from
            // another Files client must remain intact.
            if reference.identity != nil, (try? verify(reference, at: url)) != nil {
                try? FileManager.default.removeItem(at: url)
            }
            throw ReceiptFailure(cause: error)
        }
    }

    struct PublicationIntent: Codable {
        var reference: ReceivedFileReference
        var stagingName: String
    }

    struct StagingIntent: Codable {
        let id: UUID
        let bookmark: Data?
        let token: UUID
    }

    private func publish(_ source: URL, named name: String, in folder: URL,
                         folderName: String = "On My iPhone › Porthole", bookmark: Data? = nil,
                         planStage: ((StagingIntent) throws -> Void)?, clearStage: ((UUID) -> Void)?,
                         plan: ((PublicationIntent) throws -> Void)?,
                         record: (ReceivedFileReference) throws -> Void) throws -> ReceivedFileReference {
        var intent: PublicationIntent?
        let url: URL
        do {
            url = try ReceivedFileWriter.save(source, named: name, in: folder, willStage: { id, token in
                try planStage?(StagingIntent(id: id, bookmark: bookmark, token: token))
            }, didRemoveStage: clearStage) { staged, destination in
                guard let plan else { return }
                var reference = try self.makeReference(staged, folderName: folderName, bookmark: bookmark)
                reference.name = destination.lastPathComponent
                guard reference.identity != nil else { throw ReceivedStorageError.fileUnavailable }
                let draft = PublicationIntent(reference: reference, stagingName: staged.lastPathComponent)
                // Record the identity of the staging copy before the final move.
                try plan(draft)
                intent = draft
            }
        } catch {
            if intent != nil { throw ReceiptFailure(cause: error) }
            throw error
        }
        var reference: ReceivedFileReference
        do { reference = try makeReference(url, folderName: folderName, bookmark: bookmark) }
        catch { throw ReceiptFailure(cause: error) }
        if let intent { reference.id = intent.reference.id }
        try recordReference(reference, at: url, using: record)
        return reference
    }

    func recoverStaging(_ intent: StagingIntent) throws {
        func remove(in folder: URL) throws {
            try ReceivedFileWriter.removeStagingFolder(ReceivedFileWriter.stagingFolder(intent.id, in: folder),
                                                       token: intent.token)
        }
        guard let bookmark = intent.bookmark else { try remove(in: defaultFolder); return }
        #if os(iOS) || os(macOS)
        try withFolder(bookmark) { folder, _ in
            var coordinatorError: NSError?
            var result: Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinatorError) { coordinated in
                result = Result { try remove(in: coordinated) }
            }
            if let coordinatorError { throw coordinatorError }
            guard let result else { throw ReceivedStorageError.folderUnavailable }
            try result.get()
        }
        #else
        throw ReceivedStorageError.folderUnavailable
        #endif
    }

    /// Recover a completed rename after a process termination between publication
    /// and recording the receipt. A new occupant of that name is never adopted.
    func recover(_ intent: PublicationIntent, validates: @escaping (URL) -> Bool = { _ in true }) -> SavedFile? {
        let reference = intent.reference
        guard let plannedIdentity = reference.identity, ReceivedFileWriter.validName(reference.name) else { return nil }
        func matchesPlan(_ url: URL) -> Bool {
            guard let attributes = try? regularFileAttributes(url),
                  let observed = ReceivedFileIdentity(attributes: attributes),
                  (attributes[.size] as? NSNumber)?.int64Value == reference.bytes else { return false }
            // Some providers change creation metadata when publishing a staged
            // copy. A stable file number across the move is stronger evidence.
            if let number = plannedIdentity.number, let volume = plannedIdentity.volume {
                return observed.number == number && observed.volume == volume
            }
            return plannedIdentity == observed
        }
        func recoverInFolder(_ folder: URL, bookmark: Data?) -> (URL, ReceivedFileReference)? {
            let candidate = folder.appendingPathComponent(reference.name)
            if matchesPlan(candidate), validates(candidate),
               var recovered = try? makeReference(candidate, folderName: reference.folderName, bookmark: bookmark) {
                recovered.id = reference.id
                return (candidate, recovered)
            }
            let staging = intent.stagingName
            if staging.hasPrefix(".porthole-"), staging.hasSuffix(".download"),
               UUID(uuidString: String(staging.dropFirst(10).dropLast(9))) != nil {
                let discarded = folder.appendingPathComponent(staging)
                if matchesPlan(discarded) { try? FileManager.default.removeItem(at: discarded) }
            }
            return nil
        }
        if let bookmark = reference.folderBookmark {
            #if os(iOS) || os(macOS)
            return try? withFolder(bookmark) { folder, freshBookmark -> SavedFile? in
                var error: NSError?
                var recovered: ReceivedFileReference?
                NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &error) { coordinated in
                    recovered = recoverInFolder(coordinated, bookmark: freshBookmark)?.1
                }
                if let error { throw error }
                return recovered.map { SavedFile(reference: $0, localURL: nil, warning: nil) }
            }
            #else
            return nil
            #endif
        }
        guard let (url, recovered) = recoverInFolder(defaultFolder, bookmark: nil) else { return nil }
        return SavedFile(reference: recovered, localURL: url, warning: nil)
    }

    func save(_ source: URL, named name: String, planStage: ((StagingIntent) throws -> Void)? = nil,
              clearStage: ((UUID) -> Void)? = nil, plan: ((PublicationIntent) throws -> Void)? = nil,
              record: @escaping (ReceivedFileReference) throws -> Void = { _ in }) throws -> SavedFile {
        guard ReceivedFileWriter.validName(name) else { throw ReceivedStorageError.invalidName }
        let preferred = selection()
        #if os(iOS) || os(macOS)
        if let preferred {
            do {
                return try withFolder(preferred.bookmark) { folder, bookmark in
                    var coordinatorError: NSError?
                    var result: Result<ReceivedFileReference, Error>?
                    NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinatorError) { coordinated in
                        result = Result {
                            try self.publish(source, named: name, in: coordinated, folderName: preferred.name,
                                             bookmark: bookmark, planStage: planStage, clearStage: clearStage,
                                             plan: plan, record: record)
                        }
                    }
                    guard let result else {
                        if let coordinatorError { throw coordinatorError }
                        throw ReceivedStorageError.folderUnavailable
                    }
                    let ref = try result.get()
                    try? FileManager.default.removeItem(at: source)
                    return SavedFile(reference: ref, localURL: nil, warning: nil)
                }
            } catch let failure as ReceiptFailure {
                throw failure.cause
            } catch {
                // Keep the received data even if the provider or permission disappeared.
                // The notice and history use the actual fallback location.
            }
        }
        #endif
        let ref: ReceivedFileReference
        do {
            ref = try publish(source, named: name, in: defaultFolder, planStage: planStage, clearStage: clearStage,
                              plan: plan, record: record)
        }
        catch let failure as ReceiptFailure { throw failure.cause }
        try? FileManager.default.removeItem(at: source)
        return SavedFile(reference: ref, localURL: defaultFolder.appendingPathComponent(ref.name),
                         warning: preferred == nil ? nil : "Save folder unavailable. Saved to On My iPhone › Porthole instead. Choose your folder again in Settings.")
    }

    /// External files are read under coordination into an owned temporary preview.
    /// UI, Photos and the share sheet never outlive a security-scope access grant.
    func prepareForReading(_ file: ReceivedFileReference) throws -> URL {
        guard ReceivedFileWriter.validName(file.name) else { throw ReceivedStorageError.invalidName }
        reclaimOldPreviews()
        if let bookmark = file.folderBookmark {
            #if os(iOS) || os(macOS)
            return try withFolder(bookmark) { folder, _ in
                var coordinatorError: NSError?
                var result: Result<URL, Error>?
                let source = folder.appendingPathComponent(file.name)
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { coordinated in
                    result = Result {
                        try verify(file, at: coordinated)
                        let directory = previewFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let copy = directory.appendingPathComponent(file.name)
                        do { try FileManager.default.copyItem(at: coordinated, to: copy) }
                        catch { try? FileManager.default.removeItem(at: directory); throw error }
                        return copy
                    }
                }
                guard let result else {
                    if let coordinatorError { throw coordinatorError }
                    throw ReceivedStorageError.fileUnavailable
                }
                return try result.get()
            }
            #else
            throw ReceivedStorageError.folderUnavailable
            #endif
        }
        let url = defaultFolder.appendingPathComponent(file.name)
        guard (try? FileManager.default.attributesOfItem(atPath: defaultFolder.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw ReceivedStorageError.fileUnavailable
        }
        try verify(file, at: url)
        return url
    }

    func reclaimOldPreviews() {
        lock.lock()
        let needsCleanup = !cleanedPreviews
        cleanedPreviews = true
        lock.unlock()
        if needsCleanup {
            TransferStaging.removeExpiredDirectories(in: previewFolder, prefix: "",
                                                     olderThan: Date().addingTimeInterval(-86_400))
        }
    }

    func releasePreview(_ url: URL) {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        guard parent.deletingLastPathComponent() == previewFolder.standardizedFileURL,
              UUID(uuidString: parent.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: parent)
    }
}
