import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Copies picker items into a private snapshot, without reading a whole item into memory.
enum TransferStaging {
    static let maxItems = 500
    static let maxFileBytes: Int64 = 16 * 1024 * 1024 * 1024
    static let maxBatchBytes: Int64 = 32 * 1024 * 1024 * 1024
    static let desktopFileBytes: Int64 = 512 * 1024 * 1024
    private static let freeReserve: Int64 = 256 * 1024 * 1024

    enum Failure: LocalizedError {
        case cancelled, invalidFile, desktopFileLimit, batchLimit, sharedBudget, insufficientSpace, changed

        var errorDescription: String? {
            switch self {
            case .cancelled: return "File preparation was cancelled."
            case .invalidFile: return "Select non-empty regular files up to 16 GB each."
            case .desktopFileLimit: return "Porthole on the PC accepts files up to 512 MiB each. Select a smaller file."
            case .batchLimit: return "Select up to 32 GB of files per transfer."
            case .sharedBudget: return "Pending transfers use the shared file limit. Complete or discard a pending transfer first."
            case .insufficientSpace: return "Not enough space to prepare these files. Free space or select fewer files."
            case .changed: return "A selected file changed while it was being prepared. Select it again."
            }
        }
    }

    #if canImport(CryptoKit)
    static func snapshot(_ source: URL, to destination: URL, remaining: Int64,
                         reserve: ((Int64) throws -> Void)? = nil,
                         cancelled: () -> Bool) throws -> (bytes: Int64, digest: String) {
        var digest = SHA256()
        let bytes = try copy(source, to: destination, remaining: remaining, forDesktop: true, reserve: reserve,
                             inspect: { digest.update(data: $0) }, cancelled: cancelled)
        return (bytes, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    #endif

    static func copy(_ source: URL, to destination: URL, remaining: Int64, forDesktop: Bool = false,
                     reserve: ((Int64) throws -> Void)? = nil, inspect: ((Data) -> Void)? = nil,
                     cancelled: () -> Bool) throws -> Int64 {
        if cancelled() { throw Failure.cancelled }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try source.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true, let fileSize = values.fileSize,
              fileSize > 0, Int64(fileSize) <= maxFileBytes else { throw Failure.invalidFile }
        let size = Int64(fileSize)
        if forDesktop && size > desktopFileBytes { throw Failure.desktopFileLimit }
        guard size <= remaining else { throw Failure.batchLimit }

        let manager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        if let free = (try? manager.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize]) as? NSNumber,
           free.int64Value - freeReserve < size { throw Failure.insufficientSpace }
        try reserve?(size)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard !manager.fileExists(atPath: destination.path),
              manager.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteFileExists) }
        var complete = false
        defer { if !complete { try? manager.removeItem(at: destination) } }
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                  ofItemAtPath: destination.path)
        #endif
        let output = try FileHandle(forWritingTo: destination)
        var outputOpen = true
        defer { if outputOpen { try? output.close() } }
        var left = size
        while left > 0 {
            if cancelled() { throw Failure.cancelled }
            guard let chunk = try input.read(upToCount: Int(min(left, 1 << 20))), !chunk.isEmpty else { throw Failure.changed }
            try output.write(contentsOf: chunk)
            inspect?(chunk)
            left -= Int64(chunk.count)
        }
        if cancelled() { throw Failure.cancelled }
        guard (try input.read(upToCount: 1))?.isEmpty != false else { throw Failure.changed }
        try output.close()
        outputOpen = false
        complete = true
        return size
    }

    /// Reclaim stale app-owned staging directories without touching users' files.
    static func removeExpiredDirectories(in root: URL, prefix: String, olderThan expiration: Date) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let directories = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        for directory in directories {
            let name = directory.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let values = try? directory.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < expiration else { continue }
            try? manager.removeItem(at: directory)
        }
    }
}
