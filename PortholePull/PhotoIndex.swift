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
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false
            options.version = .current
            let once = NSLock()
            var finished = false
            manager.requestImage(for: asset, targetSize: CGSize(width: 96, height: 96),
                                 contentMode: .aspectFit, options: options) { image, info in
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
                guard !cancelled, let image, let sample = Self.sample(image) else { return }
                collect.lock()
                found.append(IndexedPhoto(hash: sample.hash, aspect: sample.aspect,
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

    /// Hash of the photo as it is shown, without the empty margin of a fitted thumbnail.
    private static func sample(_ image: UIImage) -> (hash: UInt64, aspect: Double)? {
        let scale = image.scale > 0 ? image.scale : 1
        let width = max(2, Int((image.size.width * scale).rounded()))
        let height = max(2, Int((image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let drawn = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cg = drawn.cgImage, cg.width >= 2, cg.height >= 2 else { return nil }
        let rowBytes = cg.width * 4
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo),
              let data = context.data else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: rowBytes * cg.height)
        let box = interior(bytes: bytes, width: cg.width, height: cg.height)
        guard box.w >= 2, box.h >= 2 else { return nil }
        let hash = PictureHash.dhash(width: box.w, height: box.h) { x, y in
            let i = ((box.y + y) * cg.width + (box.x + x)) * 4
            return PictureHash.luma(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2])
        }
        guard hash != 0 else { return nil }
        return (hash, Double(box.w) / Double(box.h))
    }

    private static func margin(_ bytes: UnsafePointer<UInt8>, _ i: Int) -> Bool {
        let alpha = Int(bytes[i + 3])
        if alpha < 16 { return true }
        let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
        let y = (r * 77 + g * 150 + b * 29) >> 8
        if max(r, g, b) - min(r, g, b) > 12 { return false }
        return y <= 32 || y >= 248
    }

    private static func interior(bytes: UnsafePointer<UInt8>, width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        func rowEmpty(_ y: Int) -> Bool {
            var ink = 0
            for x in 0..<width where !margin(bytes, (y * width + x) * 4) { ink += 1 }
            return ink * 200 <= width
        }
        func columnEmpty(_ x: Int) -> Bool {
            var ink = 0
            for y in 0..<height where !margin(bytes, (y * width + x) * 4) { ink += 1 }
            return ink * 200 <= height
        }
        var top = 0, bottom = height - 1, left = 0, right = width - 1
        while top < bottom, rowEmpty(top) { top += 1 }
        while bottom > top, rowEmpty(bottom) { bottom -= 1 }
        while left < right, columnEmpty(left) { left += 1 }
        while right > left, columnEmpty(right) { right -= 1 }
        return (left, top, right - left + 1, bottom - top + 1)
    }
}
