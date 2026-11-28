import Foundation
import Photos

/// Streams a Photo Library item's original to the PC without copying it.
/// Photos pushes the data as it reads (or downloads) it; this holds a few
/// megabytes and makes Photos wait for the rest, so memory stays small.
final class PhotoBodyReader: TransferBodyReader {
    enum Failure: LocalizedError {
        case unavailable, stalled
        var errorDescription: String? {
            switch self {
            case .unavailable: return "This item is no longer in your Photo Library."
            case .stalled: return "Photos stopped providing this item. Try again."
            }
        }
    }

    private let resource: PHAssetResource
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var buffered = 0
    private var skip: Int64 = 0
    private var started = false
    private var finished = false
    private var closed = false
    private var failure: Error?
    private var request: PHAssetResourceDataRequestID?
    private static let bufferLimit = 8 << 20
    /// Photos may first download an item from iCloud; give up only when
    /// nothing at all arrives for this long.
    private static let idleLimit: TimeInterval = 120

    init(asset identifier: String, resource name: String?) throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let resource = Self.resource(of: asset, named: name) else { throw Failure.unavailable }
        self.resource = resource
    }

    deinit { close() }

    /// The original photo or video of an item (not an edit's rendering).
    static func resource(of asset: PHAsset, named name: String?) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if let name, let match = resources.first(where: { $0.originalFilename == name }) { return match }
        let wanted: PHAssetResourceType = asset.mediaType == .video ? .video : asset.mediaType == .audio ? .audio : .photo
        return resources.first { $0.type == wanted } ?? resources.first
    }

    func seek(to offset: Int64) throws {
        condition.lock()
        defer { condition.unlock() }
        guard !started else { throw CocoaError(.fileReadUnknown) }
        skip = max(0, offset)
    }

    func read(upTo count: Int) throws -> Data {
        condition.lock()
        let begin = !started
        started = true
        condition.unlock()
        if begin { start() }

        condition.lock()
        defer { condition.unlock() }
        var lastData = Date()
        var seen = buffered
        while chunks.isEmpty, !finished, !closed {
            _ = condition.wait(until: Date().addingTimeInterval(1))
            if buffered != seen { seen = buffered; lastData = Date() }
            if chunks.isEmpty, !finished, Date().timeIntervalSince(lastData) > Self.idleLimit {
                throw Failure.stalled
            }
        }
        if let failure { throw failure }
        guard !chunks.isEmpty else { return Data() }
        var chunk = chunks.removeFirst()
        if chunk.count > count {
            let split = chunk.startIndex + count
            chunks.insert(chunk.subdata(in: split..<chunk.endIndex), at: 0)
            chunk = chunk.subdata(in: chunk.startIndex..<split)
        }
        buffered -= chunk.count
        condition.broadcast()
        return chunk
    }

    func close() {
        condition.lock()
        let id = closed ? nil : request
        closed = true
        chunks = []
        buffered = 0
        condition.broadcast()
        condition.unlock()
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    private func start() {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let id = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { [weak self] data in
            self?.receive(data)
        }, completionHandler: { [weak self] error in
            self?.complete(error)
        })
        condition.lock()
        request = id
        let cancel = closed
        condition.unlock()
        if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    private func receive(_ incoming: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        var data = incoming
        if skip > 0 {
            // Resuming: what the PC already has is read again, not sent.
            let drop = Int(min(Int64(data.count), skip))
            skip -= Int64(drop)
            data = drop == data.count ? Data() : data.subdata(in: data.startIndex + drop..<data.endIndex)
        }
        guard !data.isEmpty else { return }
        chunks.append(data)
        buffered += data.count
        condition.broadcast()
        // Photos waits here while Wi-Fi is slower than reading.
        while buffered > Self.bufferLimit, !closed { condition.wait() }
    }

    private func complete(_ error: Error?) {
        condition.lock()
        finished = true
        if let error, failure == nil, !closed { failure = error }
        condition.broadcast()
        condition.unlock()
    }
}

/// Finds the Photo Library items the Share Sheet passed on, by their
/// original file name (and size, when it is known).
enum PhotoLibraryLookup {
    static func identifier(named name: String, bytes: Int64?) -> String? {
        let base = (name as NSString).deletingPathExtension.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        let videos = ["mov", "mp4", "m4v", "hevc", "avi"]
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets: PHFetchResult<PHAsset> = ext.isEmpty
            ? PHAsset.fetchAssets(with: options)
            : PHAsset.fetchAssets(with: videos.contains(ext) ? .video : .image, options: options)
        var found: String?
        var fallback: String?
        assets.enumerateObjects { asset, _, stop in
            for resource in PHAssetResource.assetResources(for: asset) {
                let original = resource.originalFilename.lowercased()
                let originalBase = (original as NSString).deletingPathExtension
                guard original == name.lowercased() || (ext.isEmpty && originalBase == base) else { continue }
                if let bytes, let size = Self.size(of: resource), size != bytes { continue }
                if bytes == nil || Self.size(of: resource) != nil {
                    found = asset.localIdentifier
                    stop.pointee = true
                    return
                }
                if fallback == nil { fallback = asset.localIdentifier }
            }
        }
        return found ?? fallback
    }

    static func size(of resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: Selector(("fileSize"))) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }
}
