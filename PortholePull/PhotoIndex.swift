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
    private var indexing = false

    func requestAccessAndIndex() {
        if indexing || ready { return }
        indexing = true
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] access in
            DispatchQueue.main.async {
                guard access == .authorized || access == .limited else {
                    self?.indexing = false
                    self?.status = "Allow photo access in Settings"
                    self?.ready = false
                    return
                }
                self?.status = "Indexing photos"
                self?.index()
            }
        }
    }

    func match(hash: UInt64, aspect: Double) -> (asset: PHAsset?, closest: Int) {
        lock.lock()
        let items = photos
        lock.unlock()
        let picked = PictureHash.pick(query: hash, queryAspect: aspect,
                                       hashes: items.map(\.hash),
                                       aspects: items.map(\.aspect))
        guard let index = picked.index else { return (nil, picked.closest) }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [items[index].localIdentifier], options: nil).firstObject
        return (asset, picked.closest)
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
            let rawAspect = Double(asset.pixelWidth) / Double(asset.pixelHeight)
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false
            options.version = .current
            let longSide: CGFloat = 96
            let size = rawAspect >= 1
                ? CGSize(width: longSide, height: max(2, longSide / CGFloat(rawAspect)))
                : CGSize(width: max(2, longSide * CGFloat(rawAspect)), height: longSide)
            let once = NSLock()
            var finished = false
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                once.lock()
                if finished {
                    once.unlock()
                    return
                }
                finished = true
                once.unlock()
                defer { group.leave() }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                guard !cancelled, let image else { return }
                let hash = Self.hashImage(image)
                guard hash != 0 else { return }
                collect.lock()
                found.append(IndexedPhoto(hash: hash, aspect: Self.displayAspect(rawAspect, image),
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

    private static func displayAspect(_ raw: Double, _ image: UIImage) -> Double {
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return raw > 0 ? 1 / raw : raw
        default:
            return raw
        }
    }

    /// Top row first, same as the PC's video plane. UIImage.draw turns the camera file upright.
    private static func hashImage(_ image: UIImage) -> UInt64 {
        let width = max(2, Int(image.size.width.rounded()))
        let height = max(2, Int(image.size.height.rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cg = rendered.cgImage, cg.width >= 2, cg.height >= 2 else { return 0 }
        let w = cg.width
        let h = cg.height
        let rowBytes = w * 4
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return 0 }
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        return PictureHash.dhash(width: w, height: h) { x, y in
            let i = (y * w + x) * 4
            return PictureHash.luma(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2])
        }
    }
}
