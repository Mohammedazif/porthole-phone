import Photos
import UIKit

struct IndexedPhoto {
    let hash: UInt64
    let aspect: Double
    let localIdentifier: String
}

final class PhotoIndex: ObservableObject {
    @Published var status = "Photos not loaded"
    @Published var ready = false
    private let lock = NSLock()
    private var photos: [IndexedPhoto] = []
    private var manager: PHCachingImageManager?

    func requestAccessAndIndex() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] access in
            DispatchQueue.main.async {
                guard access == .authorized || access == .limited else {
                    self?.status = "Allow photo access in Settings"
                    self?.ready = false
                    return
                }
                self?.status = "Indexing photos"
                self?.index()
            }
        }
    }

    func match(hash: UInt64, aspect: Double) -> PHAsset? {
        lock.lock()
        let items = photos
        lock.unlock()
        guard let index = PictureHash.pick(query: hash, queryAspect: aspect,
                                            hashes: items.map(\.hash),
                                            aspects: items.map(\.aspect)) else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [items[index].localIdentifier], options: nil).firstObject
    }

    private func index() {
        let assets = PHAsset.fetchAssets(with: .image, options: nil)
        let total = assets.count
        if total == 0 {
            DispatchQueue.main.async {
                self.photos = []
                self.ready = true
                self.status = "No photos in the library"
            }
            return
        }
        let manager = PHCachingImageManager()
        self.manager = manager
        let group = DispatchGroup()
        let collect = NSLock()
        var found: [IndexedPhoto] = []
        var done = 0
        for n in 0..<total {
            let asset = assets.object(at: n)
            guard asset.pixelWidth >= 2, asset.pixelHeight >= 2 else { continue }
            group.enter()
            let aspect = Double(asset.pixelWidth) / Double(asset.pixelHeight)
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false
            let longSide: CGFloat = 96
            let size = aspect >= 1
                ? CGSize(width: longSide, height: longSide / CGFloat(aspect))
                : CGSize(width: longSide * CGFloat(aspect), height: longSide)
            let once = NSLock()
            var finished = false
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) {
                image, info in
                once.lock()
                if finished {
                    once.unlock()
                    return
                }
                finished = true
                once.unlock()
                defer { group.leave() }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                guard !cancelled, let cg = image?.cgImage else { return }
                let hash = Self.hash(image: cg)
                collect.lock()
                found.append(IndexedPhoto(hash: hash, aspect: aspect,
                                          localIdentifier: asset.localIdentifier))
                done += 1
                let count = done
                collect.unlock()
                if count % 40 == 0 {
                    DispatchQueue.main.async {
                        self.status = "Indexing photos \(count)"
                    }
                }
            }
        }
        group.notify(queue: .main) {
            collect.lock()
            let finished = found
            collect.unlock()
            self.manager = nil
            self.lock.lock()
            self.photos = finished
            self.lock.unlock()
            self.ready = true
            self.status = "Ready, \(finished.count) photos"
        }
    }

    private static func hash(image: CGImage) -> UInt64 {
        let width = image.width
        let height = image.height
        guard width >= 2, height >= 2 else { return 0 }
        let rowBytes = width * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        return PictureHash.dhash(width: width, height: height) { x, y in
            let i = (y * width + x) * 4
            return PictureHash.luma(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2])
        }
    }
}
