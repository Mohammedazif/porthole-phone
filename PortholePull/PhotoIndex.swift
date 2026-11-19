import AVFoundation
import Photos
import UIKit

struct IndexedPhoto {
    let luma: [UInt8]
    let gridW: Int
    let gridH: Int
    let localIdentifier: String
    let modified: Double
}

/// Small frames from across one video. Kept in a file, so each video is read once.
struct VideoEntry {
    let localIdentifier: String
    let modified: Double
    let aspect: Double
    let frames: [[UInt8]]
}

final class PhotoIndex: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var status = "Photos not loaded"
    @Published var ready = false
    private let lock = NSLock()
    private var photos: [IndexedPhoto] = []
    private var videos: [VideoEntry] = []
    /// Videos in the library, and those skipped because they are only in iCloud.
    private var videoTotal = 0
    private var videoSkipped = 0
    private let videoQueue = DispatchQueue(label: "porthole.videos", qos: .utility)
    private var manager: PHCachingImageManager?
    private var indexing = false
    private var observing = false
    private var refreshPending = false
    private var lastRefresh = Date.distantPast
    private var videoGeneration = 0

    deinit {
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    /// Reuse unchanged thumbnails; retry items that were unavailable in iCloud.
    func refreshIfNeeded() {
        if Date().timeIntervalSince(lastRefresh) >= 30 {
            requestAccessAndIndex(refresh: true)
        }
    }

    /// iCloud sync can change the library many times a minute. Index once it settles.
    private var changeWork: DispatchWorkItem?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            self.changeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.requestAccessAndIndex(refresh: true) }
            self.changeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    func requestAccessAndIndex(refresh: Bool = false) {
        if indexing {
            refreshPending = refreshPending || refresh
            return
        }
        if ready && !refresh { return }
        indexing = true
        lastRefresh = Date()
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] access in
            DispatchQueue.main.async {
                guard access == .authorized || access == .limited else {
                    self?.indexing = false
                    self?.status = "Allow photo access in Settings"
                    self?.ready = false
                    return
                }
                guard let self else { return }
                if !self.observing {
                    PHPhotoLibrary.shared().register(self)
                    self.observing = true
                }
                self.status = "Updating library"
                self.index()
            }
        }
    }

    struct Match {
        var asset: PHAsset?
        var closest = 65
        /// Best and runner-up scores, for the PC log.
        var note = ""
        /// Best and runner-up video scores, for the PC log.
        var video = ""
        /// The closest photo's thumb, which the PC saves beside its own. Always last.
        var debug = ""
    }

    /// One library item being compared with the picture on screen.
    private struct Candidate {
        let id: String
        var score: Double
        /// The item's own pattern, to tell copies of one picture from different pictures.
        var pattern: PictureHash.Pattern
    }

    /// Photos first; a picture no photo matches is then compared with video frames.
    /// detail is the PC's 64-cell copy of the picture, from PCs since phone 2.5.
    func match(hash: UInt64, aspect: Double, thumb: [Double]?, detail: [Double]? = nil,
               progress: ((String) -> Void)? = nil) -> Match {
        var found = matchPhotos(hash: hash, aspect: aspect, thumb: thumb, detail: detail)
        guard found.asset == nil, let thumb, thumb.count == PictureHash.thumbSide * PictureHash.thumbSide else {
            return found
        }
        let video = matchVideos(aspect: aspect, thumb: thumb, detail: detail, progress: progress)
        if let asset = video.asset {
            return Match(asset: asset, closest: found.closest, note: found.note, video: video.note)
        }
        found.video = video.note
        return found
    }

    /// The winner, if it leads every different picture by enough. Candidates that are
    /// copies of the winner do not count against it; among those copies the largest
    /// file wins, since that is the camera original rather than a saved copy.
    private static func decide(_ ranked: [Candidate], min: Double) -> (id: String?, note: String) {
        guard let top = ranked.first else { return (nil, "none") }
        var runner = -1.0
        var copies = [top.id]
        for other in ranked.dropFirst() {
            if PictureHash.similarity(top.pattern, other.pattern) >= PictureHash.copyMin {
                if top.score - other.score < PictureHash.requiredGap(top.score) { copies.append(other.id) }
                continue
            }
            runner = other.score
            break
        }
        var note = String(format: "%.3f %.3f", top.score, max(runner, -1))
        if copies.count > 1 { note += " copies \(copies.count)" }
        guard top.score >= min, top.score - runner >= PictureHash.requiredGap(top.score) else {
            return (nil, note)
        }
        guard copies.count > 1 else { return (top.id, note) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: copies, options: nil)
        var best: PHAsset?
        assets.enumerateObjects { asset, _, _ in
            guard let current = best else { best = asset; return }
            let size = asset.pixelWidth * asset.pixelHeight
            let bestSize = current.pixelWidth * current.pixelHeight
            let older = (asset.creationDate ?? .distantFuture) < (current.creationDate ?? .distantFuture)
            if size > bestSize || (size == bestSize && older) { best = asset }
        }
        return (best?.localIdentifier ?? top.id, note)
    }

    private func matchPhotos(hash: UInt64, aspect: Double, thumb: [Double]?, detail: [Double]?) -> Match {
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
        guard let thumb, thumb.count == PictureHash.thumbSide * PictureHash.thumbSide else {
            // A PC before the thumb: a mirrored photo lands about 15 to 17 bits away, and the
            // next library photo is often only a few bits behind that.
            let unique = bestDistance <= PictureHash.matchMax && bestDistance < second
            guard unique else { return Match(asset: nil, closest: bestDistance) }
            return Match(asset: fetch(items[best]), closest: bestDistance)
        }

        // The dHash only shortlists: everything close, and at least the 400 closest, since
        // a dark picture or one under Photos' bars can land far from its own dHash.
        let side = PictureHash.thumbSide
        let query = PictureHash.pattern(thumb, side: side)
        var order = items.indices.filter { distances[$0] < 65 }
        order.sort { distances[$0] < distances[$1] }
        let limit = max(400, order.prefix { distances[$0] <= PictureHash.candidateBits }.count)
        var ranked: [Candidate] = []
        var rankedIndex: [String: Int] = [:]
        for index in order.prefix(limit) {
            let photo = items[index]
            let crop = PictureHash.crop(width: photo.gridW, height: photo.gridH, aspect: aspect)
            let cells = PictureHash.thumb(luma: photo.luma, width: photo.gridW, crop: crop)
            let pattern = PictureHash.pattern(cells, side: side)
            ranked.append(Candidate(id: photo.localIdentifier, score: PictureHash.similarity(query, pattern),
                                    pattern: pattern))
            rankedIndex[photo.localIdentifier] = index
        }
        ranked.sort { $0.score > $1.score }

        // The photo closest by dHash, as the app sees it, for the PC to save beside its own copy.
        let near = items[ranked.first.flatMap { rankedIndex[$0.id] } ?? best]
        let nearCells = PictureHash.thumb(luma: near.luma, width: near.gridW,
                                          crop: PictureHash.crop(width: near.gridW, height: near.gridH,
                                                                 aspect: aspect))
        let debug = String(format: " near %dx%d ", near.gridW, near.gridH) + PictureHash.hex(nearCells)

        let first = Self.decide(ranked, min: PictureHash.gradientMin)
        var note = first.note
        if let id = first.id, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
            return Match(asset: asset, closest: distances[rankedIndex[id] ?? best], note: note)
        }

        // Close, but not clear: look again at the few closest in more detail. This is what
        // separates two shots of a burst, or a photo from its edited twin.
        if let top = ranked.first, top.score >= 0.5 {
            let close = ranked.prefix(8).filter { $0.score >= top.score - 0.15 }
            let detailSide = detail != nil ? PictureHash.detailSide : side
            let detailQuery = PictureHash.pattern(detail ?? thumb, side: detailSide)
            var refined: [Candidate] = []
            for candidate in close {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.id], options: nil).firstObject
                else { continue }
                let cells: [Double]
                if let sampled = Self.render(asset, longSide: 320) {
                    let crop = PictureHash.crop(width: sampled.width, height: sampled.height, aspect: aspect)
                    cells = PictureHash.thumb(luma: sampled.luma, width: sampled.width, crop: crop, side: detailSide)
                } else if let index = rankedIndex[candidate.id] {
                    let photo = items[index]
                    let crop = PictureHash.crop(width: photo.gridW, height: photo.gridH, aspect: aspect)
                    cells = PictureHash.thumb(luma: photo.luma, width: photo.gridW, crop: crop, side: detailSide)
                } else {
                    continue
                }
                let pattern = PictureHash.pattern(cells, side: detailSide)
                refined.append(Candidate(id: candidate.id, score: PictureHash.similarity(detailQuery, pattern),
                                         pattern: pattern))
            }
            refined.sort { $0.score > $1.score }
            let minimum = detail != nil ? PictureHash.detailMin : PictureHash.gradientMin
            let closer = Self.decide(refined, min: minimum)
            note += " detail " + closer.note
            if let id = closer.id, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                return Match(asset: asset, closest: distances[rankedIndex[id] ?? best], note: note)
            }
        }
        // A picture the gradients cannot place is still sent when its dHash stands well apart.
        if bestDistance <= PictureHash.matchMax, second >= bestDistance + PictureHash.matchGap,
           let top = ranked.first, top.id == items[best].localIdentifier, top.score >= 0.5 {
            return Match(asset: fetch(items[best]), closest: bestDistance, note: note)
        }
        return Match(asset: nil, closest: bestDistance, note: note, debug: debug)
    }

    private func matchVideos(aspect: Double, thumb: [Double], detail: [Double]?,
                             progress: ((String) -> Void)?) -> (asset: PHAsset?, note: String) {
        lock.lock()
        let entries = videos
        let total = videoTotal
        let skipped = videoSkipped
        lock.unlock()
        let read = "read \(entries.count)/\(total) icloud \(skipped)"
        let side = PictureHash.videoSide
        guard !entries.isEmpty, aspect > 0,
              let query = PictureHash.FrameQuery(cells: PictureHash.shrink(thumb, to: side), side: side) else {
            return (nil, "video none " + read)
        }
        // Coarse: every stored frame of every video of this shape. The best frame stands
        // for its video, so neighbouring frames of one video never compete with each other.
        struct Coarse {
            let index: Int
            let grad: Double
            let rank: Double
            let anchors: [Int]
        }
        var coarse: [Coarse] = []
        for (index, entry) in entries.enumerated() {
            if entry.aspect > 0, abs(entry.aspect - aspect) / aspect > 0.12 { continue }
            var bestGrad = -2.0
            var scored: [(frame: Int, rank: Double)] = []
            scored.reserveCapacity(entry.frames.count)
            for (frameIndex, frame) in entry.frames.enumerated() {
                let s = query.score(frame)
                bestGrad = max(bestGrad, s.grad)
                // Low-detail layout moves slowly; gradients pin the moment. Both rank.
                scored.append((frameIndex, 0.6 * s.grad + 0.4 * s.luma))
            }
            scored.sort { $0.rank > $1.rank }
            guard let lead = scored.first else { continue }
            coarse.append(Coarse(index: index, grad: bestGrad, rank: lead.rank,
                                 anchors: scored.prefix(2).map(\.frame)))
        }
        guard !coarse.isEmpty else { return (nil, "video none " + read) }
        let byGrad = coarse.sorted { $0.grad > $1.grad }
        let top = byGrad[0].grad
        let runner = byGrad.count > 1 ? byGrad[1].grad : -1
        var note = String(format: "video %.3f %.3f ", top, runner) + read
        if top >= PictureHash.videoMin, top - runner >= PictureHash.videoGap,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [entries[byGrad[0].index].localIdentifier],
                                           options: nil).firstObject {
            return (asset, note)
        }

        // Twenty-four coarse frames can miss the exact moment, above all when the camera
        // moves. Decode real frames around the closest moments of a short list.
        var seen = Set<Int>()
        var shortlist: [Coarse] = []
        for c in coarse.sorted(by: { $0.rank > $1.rank }).prefix(10) + byGrad.prefix(4) where !seen.contains(c.index) {
            seen.insert(c.index)
            shortlist.append(c)
        }
        let detailSide = detail != nil ? PictureHash.detailSide : PictureHash.thumbSide
        let detailQuery = PictureHash.pattern(detail ?? thumb, side: detailSide)
        let deadline = Date().addingTimeInterval(20)
        var refined: [Candidate] = []
        var tried = 0
        for (n, candidate) in shortlist.enumerated() {
            if Date() > deadline { break }
            progress?("Checking videos closely \(n + 1)/\(shortlist.count)")
            let entry = entries[candidate.index]
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [entry.localIdentifier], options: nil).firstObject,
                  let video = Self.loadVideo(asset) else { continue }
            let times = PictureHash.refinementTimes(duration: asset.duration, frames: entry.frames.count,
                                                    anchors: candidate.anchors)
            tried += 1
            guard let found = Self.bestFrame(in: video, times: times, aspect: aspect, query: detailQuery,
                                             side: detailSide, deadline: deadline) else { continue }
            refined.append(Candidate(id: entry.localIdentifier, score: found.score, pattern: found.pattern))
        }
        refined.sort { $0.score > $1.score }
        let minimum = detail != nil ? PictureHash.detailMin : PictureHash.gradientMin
        let verdict = Self.decide(refined, min: minimum)
        note += " refined " + verdict.note + " tried \(tried)"
        if let id = verdict.id {
            return (PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject, note)
        }
        return (nil, note)
    }

    private static func loadVideo(_ asset: PHAsset) -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false // never download unrelated candidates
        options.deliveryMode = .automatic
        options.version = .current
        let done = DispatchSemaphore(value: 0)
        var loaded: AVAsset?
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { result, _, _ in
            loaded = result
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return loaded
    }

    /// The frame among these times that best matches the picture on screen.
    private static func bestFrame(in video: AVAsset, times: [Double], aspect: Double, query: PictureHash.Pattern,
                                  side: Int, deadline: Date) -> (score: Double, pattern: PictureHash.Pattern)? {
        guard !times.isEmpty else { return nil }
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        let tolerance = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let lock = NSLock()
        var best: (score: Double, pattern: PictureHash.Pattern)?
        var remaining = times.count
        let done = DispatchSemaphore(value: 0)
        let values = times.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        generator.generateCGImagesAsynchronously(forTimes: values) { _, image, _, result, _ in
            if result == .succeeded, let image, let sampled = Self.sample(UIImage(cgImage: image)) {
                let crop = PictureHash.crop(width: sampled.width, height: sampled.height, aspect: aspect)
                let cells = PictureHash.thumb(luma: sampled.luma, width: sampled.width, crop: crop, side: side)
                let pattern = PictureHash.pattern(cells, side: side)
                let score = PictureHash.similarity(query, pattern)
                lock.lock()
                if best == nil || score > best!.score { best = (score: score, pattern: pattern) }
                lock.unlock()
            }
            lock.lock()
            remaining -= 1
            let finished = remaining == 0
            lock.unlock()
            if finished { done.signal() }
        }
        let wait = max(1.0, deadline.timeIntervalSinceNow)
        if done.wait(timeout: .now() + wait) == .timedOut {
            generator.cancelAllCGImageGeneration()
            _ = done.wait(timeout: .now() + 2)
        }
        lock.lock()
        defer { lock.unlock() }
        return best
    }

    /// A sharper copy than the index keeps, for comparing a few close candidates.
    private static func render(_ asset: PHAsset, longSide: CGFloat) -> SampledPhoto? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.version = .current
        var image: UIImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: longSide, height: longSide),
                                              contentMode: .aspectFit, options: options) { result, _ in
            image = result
        }
        guard let image else { return nil }
        return sample(image)
    }

    private func fetch(_ photo: IndexedPhoto) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [photo.localIdentifier], options: nil).firstObject
    }

    private func index() {
        // Videos are indexed by their preview frame, so a video matches near its start.
        let fetch = PHFetchOptions()
        fetch.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let assets = PHAsset.fetchAssets(with: fetch)
        let total = assets.count
        lock.lock()
        let previous = Dictionary(photos.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { _, new in new })
        videoGeneration += 1 // stop an older video scan before starting another
        lock.unlock()
        if total == 0 {
            DispatchQueue.main.async {
                self.photos = []
                self.ready = true
                self.status = "No photos in the library"
                self.finishIndex()
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
            let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
            if let old = previous[asset.localIdentifier], old.modified == modified {
                collect.lock()
                found.append(old)
                collect.unlock()
                continue
            }
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
                                          localIdentifier: asset.localIdentifier, modified: modified))
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
            self.indexVideos(photoCount: finished.count)
            self.finishIndex()
        }
    }

    private func finishIndex() {
        indexing = false
        if refreshPending {
            refreshPending = false
            requestAccessAndIndex(refresh: true)
        }
    }

    /// Reads frames from each video in the background, newest first. A video already in
    /// the cache file with the same modification date is not read again.
    private func indexVideos(photoCount: Int) {
        let fetch = PHFetchOptions()
        fetch.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        fetch.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: fetch)
        let total = assets.count
        if total == 0 { return }
        lock.lock()
        videoTotal = total
        videoSkipped = 0
        let generation = videoGeneration
        lock.unlock()
        videoQueue.async {
            var cache = Self.loadVideoCache()
            var visited = Set<String>()
            var built: [VideoEntry] = []
            var unsaved = 0
            for n in 0..<total {
                self.lock.lock()
                let current = self.videoGeneration == generation
                self.lock.unlock()
                if !current { return }
                let asset = assets.object(at: n)
                let id = asset.localIdentifier
                let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
                visited.insert(id)
                if let old = cache[id], old.modified == modified {
                    built.append(old)
                } else if let entry = autoreleasepool(invoking: { Self.sampleVideo(asset, modified: modified) }) {
                    cache[id] = entry
                    built.append(entry)
                    unsaved += 1
                } else {
                    self.lock.lock()
                    self.videoSkipped += 1
                    self.lock.unlock()
                }
                if (n + 1) % 10 == 0 || n + 1 == total {
                    self.lock.lock()
                    self.videos = built
                    self.lock.unlock()
                    let done = n + 1
                    DispatchQueue.main.async {
                        self.status = "Ready, \(photoCount) photos, videos \(done)/\(total)"
                    }
                }
                if unsaved >= 20 {
                    Self.saveVideoCache(Array(cache.values))
                    unsaved = 0
                }
            }
            cache = cache.filter { visited.contains($0.key) }
            Self.saveVideoCache(Array(cache.values))
            let count = built.count
            DispatchQueue.main.async {
                self.status = "Ready, \(photoCount) photos, \(count) videos"
            }
        }
    }

    /// Frames spread over the video, read near key frames so each one is quick.
    /// A video stored only in iCloud is skipped; its preview frame is still a photo entry.
    private static func sampleVideo(_ asset: PHAsset, modified: Double) -> VideoEntry? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .automatic
        options.version = .current
        let done = DispatchSemaphore(value: 0)
        var loaded: AVAsset?
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { result, _, _ in
            loaded = result
            done.signal()
        }
        done.wait()
        guard let video = loaded else { return nil }
        let duration = max(0.1, asset.duration)
        let step = max(1.0, duration / Double(PictureHash.videoFramesMax))
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 64)
        let tolerance = CMTime(seconds: min(step / 2, 1.0), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var frames: [[UInt8]] = []
        var aspect = 0.0
        var time = 0.0
        while time < duration && frames.count < PictureHash.videoFramesMax {
            let at = CMTime(seconds: time, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: at, actualTime: nil),
               let sampled = sample(UIImage(cgImage: image)) {
                aspect = Double(sampled.width) / Double(sampled.height)
                let whole = PictureHash.Crop(x: 0, y: 0, w: sampled.width, h: sampled.height)
                let cells = PictureHash.thumb(luma: sampled.luma, width: sampled.width, crop: whole,
                                              side: PictureHash.videoSide)
                frames.append(cells.map { UInt8(min(255, max(0, $0.rounded()))) })
            }
            time += step
        }
        if frames.isEmpty { return nil }
        return VideoEntry(localIdentifier: asset.localIdentifier, modified: modified, aspect: aspect, frames: frames)
    }

    private static var videoCacheURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("video-frames-v1.bin")
    }

    private static func saveVideoCache(_ entries: [VideoEntry]) {
        guard let url = videoCacheURL else { return }
        var data = Data("PVF1".utf8)
        func put<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        put(UInt32(entries.count))
        for entry in entries {
            let id = Array(entry.localIdentifier.utf8)
            put(UInt16(id.count))
            data.append(contentsOf: id)
            put(entry.modified)
            put(entry.aspect)
            put(UInt16(entry.frames.count))
            for frame in entry.frames {
                data.append(contentsOf: frame)
            }
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadVideoCache() -> [String: VideoEntry] {
        guard let url = videoCacheURL, let data = try? Data(contentsOf: url), data.count >= 8,
              Data(data.prefix(4)) == Data("PVF1".utf8) else { return [:] }
        let bytes = [UInt8](data)
        var at = 4
        func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, at + count <= bytes.count else { return nil }
            defer { at += count }
            return Array(bytes[at..<(at + count)])
        }
        func number<T>(_: T.Type) -> T? {
            guard let raw = take(MemoryLayout<T>.size) else { return nil }
            return raw.withUnsafeBytes { $0.load(as: T.self) }
        }
        let cells = PictureHash.videoSide * PictureHash.videoSide
        var out: [String: VideoEntry] = [:]
        guard let count = number(UInt32.self) else { return [:] }
        for _ in 0..<count {
            guard let idLength = number(UInt16.self), let idBytes = take(Int(idLength)),
                  let id = String(bytes: idBytes, encoding: .utf8),
                  let modified = number(Double.self), let aspect = number(Double.self),
                  let frameCount = number(UInt16.self) else { break }
            var frames: [[UInt8]] = []
            for _ in 0..<frameCount {
                guard let frame = take(cells) else { return out }
                frames.append(frame)
            }
            out[id] = VideoEntry(localIdentifier: id, modified: modified, aspect: aspect, frames: frames)
        }
        return out
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
        // A bitmap context already keeps the image's top row first in memory. The flip
        // that used to be here stored every photo upside down, so none ever matched.
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
