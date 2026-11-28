import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Where the bytes of a file being sent to the PC come from. Nothing is
/// copied for a Photo Library item or a file the person picked in Files: it
/// is read from where it is, each time it is sent or resumed.
enum TransferSource: Codable, Equatable {
    /// A copy Porthole made in the transfer's folder (the Share Sheet's
    /// temporary items, which iOS deletes once the sheet closes).
    case staged
    /// The original in Files, iCloud Drive or a drive, through a bookmark.
    case file(bookmark: Data)
    /// A Photo Library item: its local identifier and the original resource's file name.
    case photo(asset: String, resource: String)

    var isStaged: Bool { if case .staged = self { return true }; return false }
}

/// Reads a file's body for sending, a chunk at a time, from the start or
/// from where an earlier attempt stopped.
protocol TransferBodyReader: AnyObject {
    /// Moves to `offset`; call before the first read.
    func seek(to offset: Int64) throws
    /// Up to `count` bytes; empty at the end.
    func read(upTo count: Int) throws -> Data
    /// Safe from any thread, more than once.
    func close()
}

final class FileBodyReader: TransferBodyReader {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "The file is no longer available. Choose it again." }
    }

    private let handle: FileHandle
    private let scopedURL: URL?
    private let lock = NSLock()
    private var closed = false

    init(url: URL, scoped: Bool = false) throws {
        let accessing = scoped && url.startAccessingSecurityScopedResource()
        do { handle = try FileHandle(forReadingFrom: url) }
        catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        scopedURL = accessing ? url : nil
    }

    /// The original a bookmark points to.
    convenience init(bookmark: Data) throws {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { throw Failure.unavailable }
        do { try self.init(url: url, scoped: true) }
        catch { throw Failure.unavailable }
    }

    deinit { close() }

    func seek(to offset: Int64) throws { try handle.seek(toOffset: UInt64(offset)) }

    func read(upTo count: Int) throws -> Data {
        // Each chunk is let go at once: iOS would otherwise keep every one
        // until the whole file was read.
        try autoreleasepool { try handle.read(upToCount: count) ?? Data() }
    }

    func close() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        guard first else { return }
        try? handle.close()
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}

enum TransferMeasure {
    #if canImport(CryptoKit)
    /// Reads a whole body once for the length and SHA-256 the PC checks.
    static func measure(_ reader: TransferBodyReader, cancelled: () -> Bool,
                        progress: ((Int64) -> Void)? = nil) throws -> (bytes: Int64, digest: String) {
        var digest = SHA256()
        var bytes: Int64 = 0
        while true {
            if cancelled() { throw TransferStaging.Failure.cancelled }
            let chunk = try reader.read(upTo: 1 << 20)
            if chunk.isEmpty { break }
            digest.update(data: chunk)
            bytes += Int64(chunk.count)
            progress?(bytes)
        }
        guard bytes > 0 else { throw TransferStaging.Failure.invalidFile }
        return (bytes, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    #endif

    /// Space free for this person's files on the volume holding `url`.
    static func freeSpace(at url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage { return free }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attributes[.systemFreeSize] as? NSNumber { return free.int64Value }
        return nil
    }

    /// iOS's own temporary copy becomes the one sent: moved (or cloned on
    /// the same volume, which takes no time and no space), never read through.
    static func takeOver(_ url: URL, to target: URL) throws -> Int64 {
        let files = FileManager.default
        do { try files.moveItem(at: url, to: target) }
        catch { try files.copyItem(at: url, to: target) }
        guard let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int64(size)
    }

    /// Always left free when Porthole makes a copy, so the iPhone keeps working.
    static let keepFree: Int64 = 1 << 30
}

/// Photo Library items the Share Sheet passes on to Porthole, because a copy
/// would not fit on this iPhone. Porthole finds them in the library by name.
struct ShareHandoff: Codable, Equatable {
    struct Item: Codable, Equatable {
        let name: String
        /// Known when iOS managed its own copy for the Share Sheet.
        let bytes: Int64?
    }

    let id: UUID
    let date: Date
    let items: [Item]

    private static func url(in container: URL) -> URL {
        container.appendingPathComponent("share-handoff.json")
    }

    static func save(_ handoff: ShareHandoff, in container: URL) throws {
        try JSONEncoder().encode(handoff).write(to: url(in: container), options: .atomic)
    }

    /// The waiting handoff, if one is less than a day old.
    static func load(in container: URL) -> ShareHandoff? {
        guard let data = try? Data(contentsOf: url(in: container)),
              let handoff = try? JSONDecoder().decode(ShareHandoff.self, from: data) else { return nil }
        guard handoff.date > Date().addingTimeInterval(-86_400), !handoff.items.isEmpty else {
            clear(in: container)
            return nil
        }
        return handoff
    }

    static func clear(in container: URL) {
        try? FileManager.default.removeItem(at: url(in: container))
    }
}
