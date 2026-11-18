import Photos
import UIKit

struct IndexedPhoto {
    let luma: [UInt8]
    let gridW: Int
    let gridH: Int
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

    struct Match {
        var asset: PHAsset?
        var closest = 65
        /// Best and runner-up gradient scores, for the PC log.
        var note = ""
    }

    func match(hash: UInt64, aspect: Double, thumb: [Double]?) -> Match {
        lock.lock()
        let items = photos
        lock.unlock()
        var distances = [Int](repeating: 65, count: items.count)
        var best = -1
        var bestDistance = 65
        var second = 65
        for (index, photo) in items.enumerated() {
            let rendered = PictureHash.dhashCrop(luma: photo.luma, width: photo.gridW,
                                                 height: photo.gridH, aspect: aspect)
            if rendered == 0 && hash != 0 { continue }
            let distance = (hash ^ rendered).nonzeroBitCount
            distances[index] = distance
            if distance < bestDistance {
                second = bestDistance
                bestDistance = distance
                best = index
            } else if distance < second {
                second = distance
            }
        }
        guard best >= 0 else { return Match() }
        if let thumb, thumb.count == PictureHash.thumbSide * PictureHash.thumbSide {
            // The dHash only shortlists. Among close photos, the one whose gradients
            // follow the picture on screen wins, and only by a clear margin.
            let query = PictureHash.gradients(thumb)
            var pick = -1
            var top = -2.0
            var runner = -2.0
            for index in items.indices where distances[index] <= PictureHash.candidateBits {
                let photo = items[index]
                let crop = PictureHash.crop(width: photo.gridW, height: photo.gridH, aspect: aspect)
                let cells = PictureHash.thumb(luma: photo.luma, width: photo.gridW, crop: crop)
                let score = PictureHash.correlation(query, PictureHash.gradients(cells))
                if score > top {
                    runner = top
                    top = score
                    pick = index
                } else if score > runner {
                    runner = score
                }
            }
            var note = String(format: "%.3f %.3f", max(top, -1), max(runner, -1))
            if pick >= 0 {
                note += " \(items[pick].gridW)x\(items[pick].gridH)"
            }
            if pick >= 0, top >= PictureHash.gradientMin, top - runner >= PictureHash.gradientGap {
                return Match(asset: fetch(items[pick]), closest: distances[pick], note: note)
            }
            // A picture the gradients cannot place is still sent when its dHash stands well apart.
            if bestDistance <= PictureHash.matchMax, second >= bestDistance + PictureHash.matchGap {
                return Match(asset: fetch(items[best]), closest: bestDistance, note: note)
            }
            return Match(asset: nil, closest: bestDistance, note: note)
        }
        // A PC before the thumb: a mirrored photo lands about 15 to 17 bits away, and the
        // next library photo is often only a few bits behind that.
        let unique = bestDistance <= PictureHash.matchMax && bestDistance < second
        guard unique else { return Match(asset: nil, closest: bestDistance) }
        return Match(asset: fetch(items[best]), closest: bestDistance)
    }

    private func fetch(_ photo: IndexedPhoto) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [photo.localIdentifier], options: nil).firstObject
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
            // Fit, never fill: a box shaped from pixelWidth and pixelHeight can be the
            // other way up from the photo, and filling it cut away part of the picture.
            let longSide: CGFloat = 64
            let size = CGSize(width: longSide, height: longSide)
            let once = NSLock()
            var finished = false
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
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
                guard let sampled = Self.sample(image) else { return }
                collect.lock()
                found.append(IndexedPhoto(luma: sampled.luma, gridW: sampled.width, gridH: sampled.height,
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

    private struct SampledPhoto {
        var luma: [UInt8]
        var width: Int
        var height: Int
    }

    /// Upright luma, top row first, same orientation the PC hashes from the mirror.
    private static func sample(_ image: UIImage) -> SampledPhoto? {
        let width = max(2, Int(image.size.width.rounded()))
        let height = max(2, Int(image.size.height.rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cg = rendered.cgImage, cg.width >= 2, cg.height >= 2 else { return nil }
        let w = cg.width
        let h = cg.height
        let rowBytes = w * 4
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        var luma = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                luma[y * w + x] = PictureHash.luma(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2])
            }
        }
        return SampledPhoto(luma: luma, width: w, height: h)
    }
}
