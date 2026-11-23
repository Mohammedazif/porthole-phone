import Foundation
import Photos

/// Bounds a PhotoKit resource download before it reaches the transport.
final class PhotoExportStaging {
    let file: URL
    private let sourceIdentifier: String
    private let lock = NSLock()
    private let handle: FileHandle
    private var bytes: Int64 = 0
    private var request: PHAssetResourceDataRequestID?
    private var active = true

    init(file: URL, sourceIdentifier: String) throws {
        self.file = file
        self.sourceIdentifier = sourceIdentifier
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard manager.createFile(atPath: file.path, contents: nil, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]) else { throw CocoaError(.fileWriteUnknown) }
        do { handle = try FileHandle(forWritingTo: file) }
        catch { try? manager.removeItem(at: file); throw error }
    }

    func canReadSource(verifyExistence: Bool = false) -> Bool {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { return false }
        if access == .authorized, !verifyExistence { return true }
        return PHAsset.fetchAssets(withLocalIdentifiers: [sourceIdentifier], options: nil).firstObject != nil
    }

    func start(resource: PHAssetResource, options: PHAssetResourceRequestOptions,
               completion: @escaping (Int64?) -> Void) {
        let manager = PHAssetResourceManager.default()
        let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { [weak self] data in
            guard let self else { return }
            if self.append(data) == false {
                self.cancel()
                completion(nil)
            }
        }, completionHandler: { [weak self] error in
            guard let self, let size = self.finish(error: error) else { return }
            completion(size > 0 ? size : nil)
        })
        lock.lock()
        if active {
            request = id
            lock.unlock()
        } else {
            lock.unlock()
            manager.cancelDataRequest(id)
        }
    }

    private func append(_ data: Data) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        guard Int64(data.count) <= 512 * 1024 * 1024 - bytes else { return false }
        do {
            try handle.write(contentsOf: data)
            bytes += Int64(data.count)
            return true
        } catch { return false }
    }

    private func finish(error: Error?) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        active = false
        let closed: Bool
        do { try handle.close(); closed = true }
        catch { closed = false }
        if error == nil, closed, bytes > 0 { return bytes }
        try? FileManager.default.removeItem(at: file)
        return 0
    }

    func cancel() {
        lock.lock()
        let id = active ? request : nil
        if active {
            active = false
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        lock.unlock()
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
}
