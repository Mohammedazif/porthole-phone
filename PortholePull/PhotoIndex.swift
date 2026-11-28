import AVFoundation
import Combine
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
    struct Frame {
        let seconds: Double
        let pixels: [UInt8]
    }
    let aspect: Double
    let frames: [Frame]
}

final class PhotoIndex: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var status = "Photo library not indexed"
    @Published var ready = false
    @Published private(set) var accessLabel = "Not requested"
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    private let lock = NSLock()
    private var photos: [IndexedPhoto] = []
    private var videos: [VideoEntry] = []
    /// Videos in the library and those that did not yield local frames.
    private var videoTotal = 0
    private var videoSkipped = 0
    private let videoQueue = DispatchQueue(label: "porthole.videos", qos: .utility)
    private var indexing = false
    private var observing = false
    private var refreshPending = false
    // Permission and snapshot changes invalidate work already in flight.
    private var libraryAccess: PHAuthorizationStatus?
    private var libraryGeneration = 0
    private var videoGeneration = 0
    private var photosGeneration = 0
    // Match jobs can run off the companion's queue. Protect fitted data with the
    // same lock as the photo snapshot, and clear it with a permission change.
    private var fitKey = ""
    private var fitCells: [[UInt8]] = []
    private static let photoPixelBudget = 128 * 1024 * 1024
    private static let videoPixelBudget = 48 * 1024 * 1024
    private static let maxPhotoEntries = 80_000
    private static let maxVideoEntries = 12_000
    private let indexQueue = DispatchQueue(label: "porthole.index", qos: .utility)
    /// Run bounded thumbnail requests and sampling away from the main thread.
    private let sampleQueue = DispatchQueue(label: "porthole.sample", qos: .utility, attributes: .concurrent)

    deinit {
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    func refreshAuthorization() {
        noteAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Warms the index when access was already given; never asks for it.
    /// Once ready it stays ready: library changes come from the change
    /// observer while Porthole runs, and from iOS's change history since the
    /// last time it ran, so nothing is read again from the start.
    func refreshIfNeeded() {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        noteAccess(access)
        if canAccessLibrary, !indexing, !ready {
            requestAccessAndIndex(refresh: true)
        }
    }

    enum MatchReadiness { case ready, preparing, accessRequired }

    func prepareMatch() -> MatchReadiness {
        refreshIfNeeded()
        guard canAccessLibrary else { return .accessRequired }
        return ready ? .ready : .preparing
    }

    /// iCloud sync can change the library repeatedly. Refetch once it settles,
    /// but immediately retire work and any limited-library snapshot on a change.
    private var changeWork: DispatchWorkItem?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        lock.lock()
        // What's indexed stays usable; the update reads only what changed.
        if access != libraryAccess {
            invalidateLocked(access: access)
        } else {
            libraryGeneration += 1
        }
        lock.unlock()
        DispatchQueue.main.async {
            let latest = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            self.noteAccess(latest)
            self.changeWork?.cancel()
            guard self.canAccessLibrary else { return }
            let work = DispatchWorkItem { [weak self] in self?.requestAccessAndIndex(refresh: true) }
            self.changeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    func requestAccessAndIndex(refresh: Bool = false) {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        noteAccess(access)
        if indexing {
            refreshPending = refreshPending || refresh
            return
        }
        if ready && !refresh { return }
        indexing = true
        if access == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.startIndex(access: PHPhotoLibrary.authorizationStatus(for: .readWrite))
                }
            }
        } else {
            startIndex(access: access)
        }
    }

    private func startIndex(access: PHAuthorizationStatus) {
        noteAccess(access)
        guard canAccessLibrary else { finishIndex(); return }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        if !ready { status = "Checking photo library" }
        lock.lock()
        let generation = libraryGeneration
        lock.unlock()
        indexQueue.async {
            self.index(generation: generation, access: access,
                       diskCache: access == .authorized || access == .limited)
        }
    }

    private func invalidateLocked(access: PHAuthorizationStatus) {
        libraryAccess = access
        libraryGeneration += 1
        photosGeneration += 1
        videoGeneration += 1
        photos.removeAll()
        videos.removeAll()
        videoTotal = 0
        videoSkipped = 0
        fitKey = ""
        fitCells.removeAll()
        if access != .authorized && access != .limited {
            for name in ["photo-index-v2.bin", "video-frames-v2.bin", Self.tokenName] {
                if let url = Self.cacheURL(name) { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    private func noteAccess(_ access: PHAuthorizationStatus) {
        let old = authorizationStatus
        authorizationStatus = access
        lock.lock()
        if libraryAccess == nil {
            Self.removeLegacyCaches()
        }
        if libraryAccess != access { invalidateLocked(access: access) }
        lock.unlock()
        if old != access { ready = false }
        switch access {
        case .authorized: accessLabel = "Full access"
        case .limited: accessLabel = "Limited access"
        case .denied: accessLabel = "Access denied"
        case .restricted: accessLabel = "Restricted"
        case .notDetermined: accessLabel = "Not requested"
        @unknown default: accessLabel = "Unknown"
        }
        if !canAccessLibrary {
            ready = false
            status = access == .restricted ? "Photo access is restricted by device settings."
                : access == .notDetermined ? "Photo access has not been requested."
                : "Photo access required. Review permissions in Settings."
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentLocked(generation)
    }

    private func isCurrentLocked(_ generation: Int) -> Bool {
        generation == libraryGeneration && (libraryAccess == .authorized || libraryAccess == .limited)
            && PHPhotoLibrary.authorizationStatus(for: .readWrite) == libraryAccess
    }

    private static func itemCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "item" : "items")"
    }

    private static func currentAsset(_ id: String, modified: Double) -> PHAsset? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              (asset.modificationDate?.timeIntervalSince1970 ?? 0) == modified else { return nil }
        return asset
    }

    private var canAccessLibrary: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    struct Match {
        var asset: PHAsset?
        var closest = 65
        /// Best and runner-up scores, for the PC log.
        var note = ""
        /// Best and runner-up video scores, for the PC log.
        var video = ""
        var videoUnavailable = false
        /// Two different pictures that both clear the minimum when neither wins.
        var choices: [String] = []
    }

    /// The whole phone screen under a drag, from PCs since phone 2.6. Photos shows one
    /// item fitted to the screen, so each library item can be placed on it the same way:
    /// a black screenshot on Photos' black needs no edges to be found.
    struct Screen {
        let aspect: Double
        let thumb: [Double]
        let detail: [Double]

        var placement: PictureHash.Placement {
            .fit(screen: aspect, background: PictureHash.background(thumb, side: PictureHash.thumbSide))
        }
    }

    /// One library item being compared with the picture on screen.
    private struct Candidate {
        let id: String
        var score: Double
        /// The item's own pattern, to tell copies of one picture from different pictures.
        var pattern: PictureHash.Pattern
        /// Where its best cut sat, for a cropped picture.
        var along = 0.5
    }

    /// The picture the PC cut out first, then the whole screen; photos, then videos.
    func match(hash: UInt64, aspect: Double, thumb: [Double]?, detail: [Double]? = nil,
               screen: Screen? = nil, isCancelled: @escaping () -> Bool = { false },
               progress: ((String) -> Void)? = nil) -> Match {
        guard (0.05...20).contains(aspect), screen.map({ (0.05...20).contains($0.aspect) }) ?? true else {
            return Match()
        }
        lock.lock()
        let generation = libraryGeneration
        lock.unlock()
        let deadline = DispatchTime.now() + .seconds(14)
        let authorized = { !isCancelled() && self.isCurrent(generation) }
        let current = { DispatchTime.now() < deadline && authorized() }
        guard current() else { return Match() }
        let result = matchCurrent(hash: hash, aspect: aspect, thumb: thumb, detail: detail, screen: screen,
                                  deadline: deadline, current: current, progress: progress)
        return authorized() && (DispatchTime.now() < deadline || result.videoUnavailable) ? result : Match()
    }

    private func matchCurrent(hash: UInt64, aspect: Double, thumb: [Double]?, detail: [Double]?,
                              screen: Screen?, deadline: DispatchTime, current: @escaping () -> Bool,
                              progress: ((String) -> Void)?) -> Match {
        // With no edges to find, the PC sends the whole screen as the picture too.
        let onlyScreen = screen != nil && thumb == screen?.thumb
        var found = Match()
        if !onlyScreen {
            found = matchPhotos(hash: hash, aspect: aspect, thumb: thumb, detail: detail, current: current)
            if found.asset != nil || !found.choices.isEmpty { return found }
        }
        guard current() else { return Match() }
        if let screen {
            progress?("Analyzing shared screen")
            let fitted = matchFitted(screen, current: current)
            found.note += (found.note.isEmpty ? "" : " ") + "screen " + fitted.note
            if let asset = fitted.asset {
                found.asset = asset
                return found
            }
            if !fitted.choices.isEmpty {
                found.choices = fitted.choices
                return found
            }
        }
        var videoNotes: [String] = []
        if !onlyScreen, let thumb, thumb.count == PictureHash.thumbSide * PictureHash.thumbSide {
            let video = matchVideos(placement: .crop(aspect: aspect), thumb: thumb, detail: detail,
                                    shapeFilter: aspect, deadline: deadline, current: current, progress: progress)
            if let asset = video.asset { return Match(asset: asset, closest: found.closest, note: found.note, video: video.note) }
            videoNotes.append(video.note)
            found.videoUnavailable = video.unavailable
            if !video.choices.isEmpty {
                found.video = video.note
                found.choices = video.choices
                return found
            }
        }
        if let screen, current() {
            let video = matchVideos(placement: screen.placement, thumb: screen.thumb, detail: screen.detail,
                                    shapeFilter: nil, deadline: deadline, current: current, progress: progress)
            if let asset = video.asset {
                return Match(asset: asset, closest: found.closest, note: found.note, video: "screen " + video.note)
            }
            videoNotes.append("screen " + video.note)
            found.videoUnavailable = found.videoUnavailable || video.unavailable
            found.choices = video.choices
        }
        found.video = videoNotes.joined(separator: " ")
        return found
    }

    /// The winner, if it leads every different picture by enough. Candidates that are
    /// copies of the winner do not count against it; among those copies the largest
    /// file wins, since that is the camera original rather than a saved copy.
    private static func decide(_ ranked: [Candidate], min: Double) -> (id: String?, note: String, choices: [String]) {
        guard let top = ranked.first else { return (nil, "none", []) }
        var runner = -1.0
        var runnerId: String?
        var copies = [top.id]
        for other in ranked.dropFirst() {
            if PictureHash.similarity(top.pattern, other.pattern) >= PictureHash.copyMin {
                if top.score - other.score < PictureHash.requiredGap(top.score) { copies.append(other.id) }
                continue
            }
            runner = other.score
            runnerId = other.id
            break
        }
        var note = String(format: "%.3f %.3f", top.score, max(runner, -1))
        if copies.count > 1 { note += " copies \(copies.count)" }
        guard top.score >= min, top.score - runner >= PictureHash.requiredGap(top.score) else {
            var choices: [String] = []
            if let runnerId, top.score >= min, runner >= min {
                choices = [top.id, runnerId]
            }
            return (nil, note, choices)
        }
        guard copies.count > 1 else { return (top.id, note, []) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: copies, options: nil)
        var best: PHAsset?
        assets.enumerateObjects { asset, _, _ in
            guard let current = best else { best = asset; return }
            let size = asset.pixelWidth * asset.pixelHeight
            let bestSize = current.pixelWidth * current.pixelHeight
            let older = (asset.creationDate ?? .distantFuture) < (current.creationDate ?? .distantFuture)
            if size > bestSize || (size == bestSize && older) { best = asset }
        }
        return (best?.localIdentifier ?? top.id, note, [])
    }

    /// Ranked by the index's small copies, then the close ones again on sharper copies.
    /// This is what separates two shots of a burst, or a photo from its edited twin. A
    /// win that is not near-perfect is confirmed the same way: a wrong file is worse
    /// than none, and a page of text can look like a list on a phone at 32 cells.
    private func closerLook(_ ranked: [Candidate], items: [IndexedPhoto], at position: [String: Int],
                            placement: @escaping (Candidate) -> PictureHash.Placement, detail: [Double]?,
                            thumb: [Double], current: @escaping () -> Bool) -> (id: String?, note: String, choices: [String]) {
        guard current() else { return (nil, "cancelled", []) }
        let first = Self.decide(ranked, min: PictureHash.gradientMin)
        guard let top = ranked.first else { return first }
        let runner = ranked.count > 1 ? ranked[1].score : -1
        if first.id != nil, top.score >= 0.92, top.score - runner >= 0.10 { return first }
        guard top.score >= 0.4 else { return first }
        let close = ranked.prefix(8).filter { $0.score >= top.score - 0.15 }
        let side = detail != nil ? PictureHash.detailSide : PictureHash.thumbSide
        let query = PictureHash.pattern(detail ?? thumb, side: side)
        // Photos draws each sharper copy in its own time: ask for them all at once.
        let candidates = Array(close)
        var refined: [Candidate] = Parallel.map(candidates.count, serialBelow: 2) { (k: Int) -> Candidate? in
            guard current() else { return nil }
            let candidate = candidates[k]
            guard let index = position[candidate.id] else { return nil }
            let photo = items[index]
            guard let asset = Self.currentAsset(candidate.id, modified: photo.modified) else { return nil }
            let luma: [UInt8], width: Int, height: Int
            if let sampled = Self.render(asset, longSide: 320, current: current) {
                (luma, width, height) = (sampled.luma, sampled.width, sampled.height)
            } else {
                (luma, width, height) = (photo.luma, photo.gridW, photo.gridH)
            }
            // Each candidate at its best of a few zooms: the right one gains far more than
            // a different picture does, so the lead grows.
            // Copies are told apart by the unzoomed pattern, so two copies stay copies
            // whichever zoom each scored best at.
            var best = -1.0
            var plain: PictureHash.Pattern?
            for zoom in PictureHash.zooms {
                let cells = PictureHash.cells(luma: luma, width: width, height: height,
                                              placement: placement(candidate).zoomed(zoom), side: side)
                let pattern = PictureHash.pattern(cells, side: side)
                if plain == nil { plain = pattern }
                best = max(best, PictureHash.similarity(query, pattern))
            }
            guard let plain else { return nil }
            return Candidate(id: candidate.id, score: best, pattern: plain, along: candidate.along)
        }.compactMap { $0 }
        refined.sort { $0.score > $1.score }
        let minimum = detail != nil ? PictureHash.detailMin : PictureHash.gradientMin
        let closer = Self.decide(refined, min: minimum)
        let note = first.note + " detail " + closer.note
        if closer.id != nil { return (closer.id, note, []) }
        // The first pick stands only when the sharper look still puts it first, clearly.
        if let id = first.id, let best = refined.first, best.id == top.id, best.score >= 0.5,
           best.score - (refined.count > 1 ? refined[1].score : -1) >= 0.05 {
            return (id, note + " kept", [])
        }
        let choices = closer.choices.isEmpty ? first.choices : closer.choices
        return (nil, note + (first.id != nil ? " unconfirmed" : ""), choices)
    }

    private func matchPhotos(hash: UInt64, aspect: Double, thumb: [Double]?, detail: [Double]?,
                             current: @escaping () -> Bool) -> Match {
        lock.lock()
        let items = photos
        lock.unlock()
        let started = DispatchTime.now()
        // The cut may not be centred: the closest of three positions counts, and where it
        // sat is kept for scoring below.
        let hashed: [(distance: Int, along: Double)] = Parallel.map(items.count) { (index: Int) -> (distance: Int, along: Double) in
            if index.isMultiple(of: 64), !current() { return (65, 0.5) }
            let photo = items[index]
            var distance = 65, at = 0.5
            for along in Self.slides(photo, aspect) ? [0.5, 0.2, 0.8] : [0.5] {
                let rendered = PictureHash.dhashCrop(luma: photo.luma, width: photo.gridW,
                                                     height: photo.gridH, aspect: aspect, along: along)
                if rendered == 0 && hash != 0 { continue }
                let d = (hash ^ rendered).nonzeroBitCount
                if d < distance {
                    distance = d
                    at = along
                }
            }
            return (distance, at)
        }
        guard current() else { return Match() }
        let hashMs = Parallel.ms(since: started)
        var distances = [Int](repeating: 65, count: items.count)
        var best = -1
        var bestDistance = 65
        for index in items.indices {
            let distance = hashed[index].distance
            if distance == 65 { continue }
            distances[index] = distance
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        guard best >= 0 else { return Match() }
        guard let thumb, thumb.count == PictureHash.thumbSide * PictureHash.thumbSide else {
            // A hash alone proposes a candidate. Original transfer requires image evidence.
            return Match(closest: bestDistance, note: "thumbnail required")
        }

        // Bound the detailed work even if a large library shares one perceptual
        // hash. Keep coarse scores for every asset, but never retain an image
        // pattern for every hash near the requested item.
        let side = PictureHash.thumbSide
        let query = PictureHash.pattern(thumb, side: side)
        var order = items.indices.filter { distances[$0] < 65 }
        order.sort { distances[$0] < distances[$1] }
        let closeCount = order.prefix { distances[$0] <= PictureHash.candidateBits }.count
        let limit = min(768, max(400, closeCount))
        // Each at the centre and where its dHash sat; then the closest few at every cut,
        // so a thumbnail cut away from the centre still wins without scoring thousands
        // of photos seven times over.
        let picked = Array(order.prefix(limit))
        var ranked: [Candidate] = Parallel.map(picked.count) { (k: Int) -> Candidate in
            let photo = items[picked[k]]
            let along = hashed[picked[k]].along
            return Self.scored(photo, aspect: aspect, alongs: along == 0.5 ? [0.5] : [0.5, along],
                               query: query, side: side)
        }
        var position: [String: Int] = [:]
        for index in picked { position[items[index].localIdentifier] = index }
        ranked.sort { $0.score > $1.score }
        let head = min(Self.everyCut, ranked.count)
        let wider: [Candidate] = Parallel.map(head, serialBelow: 2) { (k: Int) -> Candidate in
            let candidate = ranked[k]
            guard let index = position[candidate.id], Self.slides(items[index], aspect) else { return candidate }
            let all = Self.scored(items[index], aspect: aspect, alongs: PictureHash.alongs, query: query, side: side)
            return all.score > candidate.score ? all : candidate
        }
        ranked.replaceSubrange(0..<head, with: wider)
        ranked.sort { $0.score > $1.score }

        let rankMs = Parallel.ms(since: started) - hashMs
        var verdict = closerLook(ranked, items: items, at: position,
                                 placement: { .crop(aspect: aspect, along: $0.along) },
                                 detail: detail, thumb: thumb, current: current)
        verdict.note += " ms hash \(hashMs) rank \(rankMs) look \(Parallel.ms(since: started) - hashMs - rankMs)"
        if let id = verdict.id, let index = position[id],
           let asset = Self.currentAsset(id, modified: items[index].modified) {
            return Match(asset: asset, closest: distances[index], note: verdict.note)
        }
        return Match(asset: nil, closest: bestDistance, note: verdict.note,
                     choices: Self.currentChoices(verdict.choices, items: items, position: position))
    }

    private static func currentChoices(_ ids: [String], items: [IndexedPhoto], position: [String: Int]) -> [String] {
        let valid = ids.filter { id in
            guard let index = position[id] else { return false }
            return currentAsset(id, modified: items[index].modified) != nil
        }
        return valid.count > 1 ? valid : []
    }

    /// Candidates scored at every cut position in the ranking above.
    private static let everyCut = 40

    /// Whether a photo's shape differs from the cut on screen, so the cut can slide.
    private static func slides(_ photo: IndexedPhoto, _ aspect: Double) -> Bool {
        guard photo.gridH > 0, aspect > 0 else { return false }
        return abs(Double(photo.gridW) / Double(photo.gridH) - aspect) / aspect >= 0.02
    }

    /// A photo's best score among these cut positions.
    private static func scored(_ photo: IndexedPhoto, aspect: Double, alongs: [Double],
                               query: PictureHash.Pattern, side: Int) -> Candidate {
        var best: Candidate?
        for along in alongs {
            let cells = PictureHash.cells(luma: photo.luma, width: photo.gridW, height: photo.gridH,
                                          placement: .crop(aspect: aspect, along: along), side: side)
            let pattern = PictureHash.pattern(cells, side: side)
            let score = PictureHash.similarity(query, pattern)
            if best == nil || score > best!.score {
                best = Candidate(id: photo.localIdentifier, score: score, pattern: pattern, along: along)
            }
        }
        return best!
    }

    /// Every library photo placed on the whole screen the way Photos shows it. A quick
    /// pass at 16 cells keeps the 300 closest; those are compared properly.
    private func matchFitted(_ screen: Screen, current: @escaping () -> Bool) -> (asset: PHAsset?, note: String, choices: [String]) {
        lock.lock()
        let items = photos
        let generation = photosGeneration
        let cachedKey = fitKey
        let cachedCells = fitCells
        lock.unlock()
        let placement = screen.placement
        let quickSide = PictureHash.videoSide
        guard !items.isEmpty, screen.thumb.count == PictureHash.thumbSide * PictureHash.thumbSide,
              let quick = PictureHash.FrameQuery(cells: PictureHash.shrink(screen.thumb, to: quickSide), side: quickSide)
        else { return (nil, "none", []) }
        let background = PictureHash.background(screen.thumb, side: PictureHash.thumbSide)
        guard (0...255).contains(background) else { return (nil, "invalid preview", []) }
        let key = "\(generation) \(screen.aspect) \(background)"
        let all: [[UInt8]]
        if key == cachedKey && cachedCells.count == items.count {
            all = cachedCells
        } else {
            all = Parallel.map(items.count) { (index: Int) -> [UInt8] in
                if index.isMultiple(of: 64), !current() { return [] }
                let photo = items[index]
                return PictureHash.cells(luma: photo.luma, width: photo.gridW, height: photo.gridH,
                                         placement: placement, side: quickSide, samples: 2)
                    .map { UInt8(min(255, max(0, $0.rounded()))) }
            }
            guard current() else { return (nil, "cancelled", []) }
            lock.lock()
            if photosGeneration == generation {
                fitKey = key
                fitCells = all
            }
            lock.unlock()
        }
        var rough: [(index: Int, rank: Double)] = Parallel.map(all.count) { (index: Int) -> (index: Int, rank: Double) in
            let s = quick.score(all[index])
            return (index, 0.6 * s.grad + 0.4 * s.luma)
        }
        rough.sort { $0.rank > $1.rank }
        let side = PictureHash.thumbSide
        let query = PictureHash.pattern(screen.thumb, side: side)
        let shortlist = Array(rough.prefix(300))
        var ranked: [Candidate] = Parallel.map(shortlist.count, serialBelow: 2) { (k: Int) -> Candidate in
            let photo = items[shortlist[k].index]
            let cells = PictureHash.cells(luma: photo.luma, width: photo.gridW, height: photo.gridH,
                                          placement: placement, side: side)
            let pattern = PictureHash.pattern(cells, side: side)
            return Candidate(id: photo.localIdentifier, score: PictureHash.similarity(query, pattern),
                             pattern: pattern)
        }
        var position: [String: Int] = [:]
        for entry in shortlist { position[items[entry.index].localIdentifier] = entry.index }
        ranked.sort { $0.score > $1.score }
        let verdict = closerLook(ranked, items: items, at: position, placement: { _ in placement },
                                 detail: screen.detail.isEmpty ? nil : screen.detail, thumb: screen.thumb, current: current)
        guard let id = verdict.id, let index = position[id] else {
            return (nil, verdict.note, Self.currentChoices(verdict.choices, items: items, position: position))
        }
        return (Self.currentAsset(id, modified: items[index].modified), verdict.note, [])
    }

    private struct VideoMatch {
        var asset: PHAsset?
        var note: String
        var choices: [String] = []
        var unavailable = false
    }

    private func matchVideos(placement: PictureHash.Placement, thumb: [Double], detail: [Double]?,
                             shapeFilter: Double?, deadline: DispatchTime, current: @escaping () -> Bool,
                             progress: ((String) -> Void)?) -> VideoMatch {
        lock.lock()
        let entries = videos
        let total = videoTotal
        let skipped = videoSkipped
        lock.unlock()
        let started = DispatchTime.now()
        let read = "read \(entries.count)/\(total) unavailable \(skipped)"
        let side = PictureHash.videoSide
        guard !entries.isEmpty,
              let query = PictureHash.FrameQuery(cells: PictureHash.shrink(thumb, to: side), side: side) else {
            return VideoMatch(note: "video none " + read)
        }
        var fitted = false
        if case .fit = placement { fitted = true }
        // Coarse: every stored frame of every candidate video. The best frame stands
        // for its video, so neighbouring frames of one video never compete with each other.
        struct Coarse {
            let index: Int
            let grad: Double
            let rank: Double
            let anchors: [Int]
        }
        guard current() else { return VideoMatch(note: "cancelled") }
        let coarse: [Coarse] = Parallel.map(entries.count) { (index: Int) -> Coarse? in
            if index.isMultiple(of: 16), !current() { return nil }
            let entry = entries[index]
            // Cropped to the shape on screen rather than skipped: a library thumbnail is a
            // square cut from the middle of a tall or wide video.
            if entry.aspect <= 0 { return nil }
            var bestGrad = -2.0
            var scored: [(frame: Int, rank: Double)] = []
            scored.reserveCapacity(entry.frames.count)
            for (frameIndex, sample) in entry.frames.enumerated() {
                let frame = sample.pixels
                let pixels: [UInt8]
                if !fitted, let aspect = shapeFilter, aspect > 0, abs(entry.aspect - aspect) / aspect <= 0.03 {
                    pixels = frame // already this shape
                } else {
                    pixels = PictureHash.cells(luma: frame, width: side, height: side, placement: placement,
                                               side: side, shape: entry.aspect, samples: 2)
                        .map { UInt8(min(255, max(0, $0.rounded()))) }
                }
                let s = query.score(pixels)
                bestGrad = max(bestGrad, s.grad)
                // Low-detail layout moves slowly; gradients pin the moment. Both rank.
                scored.append((frameIndex, 0.6 * s.grad + 0.4 * s.luma))
            }
            scored.sort { $0.rank > $1.rank }
            guard let lead = scored.first else { return nil }
            return Coarse(index: index, grad: bestGrad, rank: lead.rank, anchors: scored.prefix(2).map(\.frame))
        }.compactMap { $0 }
        guard current(), !coarse.isEmpty else { return VideoMatch(note: "video none " + read) }
        let byGrad = coarse.sorted { $0.grad > $1.grad }
        let top = byGrad[0].grad
        let runner = byGrad.count > 1 ? byGrad[1].grad : -1
        var note = String(format: "video %.3f %.3f ", top, runner) + read + " ms \(Parallel.ms(since: started))"
        let leading = entries[byGrad[0].index]
        if !fitted, top >= PictureHash.videoMin, top - runner >= PictureHash.videoGap,
           let asset = Self.currentAsset(leading.localIdentifier, modified: leading.modified) {
            return VideoMatch(asset: asset, note: note)
        }

        // Decoding takes seconds. When no video is even near, such as on the home screen,
        // answer now. A video dragged mid-motion scored 0.44 here before it was refined.
        if top < (fitted ? 0.40 : 0.30) {
            return VideoMatch(note: note + " not near")
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
        var refined: [Candidate] = []
        var sources: [String: VideoEntry] = [:]
        var unavailable = 0
        for (n, candidate) in shortlist.enumerated() {
            guard current() else { unavailable += shortlist.count - n; break }
            progress?("Analyzing video matches · \(n + 1)/\(shortlist.count)")
            let entry = entries[candidate.index]
            let candidateDeadline = min(deadline, .now() + .seconds(3))
            guard let asset = Self.currentAsset(entry.localIdentifier, modified: entry.modified),
                  let video = Self.loadVideo(asset, deadline: min(deadline, .now() + .seconds(2)), current: current)
            else { unavailable += 1; continue }
            let times = PictureHash.refinementTimes(duration: asset.duration,
                                                    anchors: candidate.anchors.map { entry.frames[$0].seconds })
            guard let found = Self.bestFrame(in: video, times: times, placement: placement, query: detailQuery,
                                             side: detailSide, deadline: candidateDeadline, current: current)
            else { unavailable += 1; continue }
            refined.append(Candidate(id: entry.localIdentifier, score: found.score, pattern: found.pattern))
            sources[entry.localIdentifier] = entry
        }
        refined.sort { $0.score > $1.score }
        let minimum = detail != nil ? PictureHash.detailMin : PictureHash.gradientMin
        if unavailable > 0 {
            // Missing evidence cannot break a tie in favor of the remaining videos.
            let choices = refined.lazy.filter { $0.score >= minimum }.compactMap { candidate -> String? in
                guard let entry = sources[candidate.id] else { return nil }
                return Self.currentAsset(candidate.id, modified: entry.modified)?.localIdentifier
            }.prefix(2)
            return VideoMatch(note: note + " refinement unavailable \(unavailable)/\(shortlist.count)",
                              choices: Array(choices), unavailable: true)
        }
        let verdict = Self.decide(refined, min: minimum)
        note += " refined " + verdict.note + " tried \(refined.count)"
        if let id = verdict.id, let entry = sources[id] {
            let asset = Self.currentAsset(id, modified: entry.modified)
            return VideoMatch(asset: asset, note: note, unavailable: asset == nil)
        }
        let choices = verdict.choices.compactMap { id -> String? in
            guard let entry = sources[id] else { return nil }
            return Self.currentAsset(id, modified: entry.modified)?.localIdentifier
        }
        return VideoMatch(note: note, choices: choices, unavailable: choices.count < verdict.choices.count)
    }

    private final class CallbackResults<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private let signal = DispatchSemaphore(value: 0)
        private var remaining: Int
        private var accepting = true
        private var values: [Value] = []

        init(count: Int) { remaining = count }

        func complete(_ value: Value?) {
            lock.lock()
            defer { lock.unlock() }
            guard accepting, remaining > 0 else { return }
            if let value { values.append(value) }
            remaining -= 1
            if remaining == 0 { signal.signal() }
        }

        func wait(deadline: DispatchTime, current: () -> Bool) -> [Value]? {
            while current(), DispatchTime.now() < deadline {
                if signal.wait(timeout: min(deadline, .now() + .milliseconds(125))) == .success {
                    break
                }
            }
            lock.lock()
            defer { lock.unlock() }
            accepting = false
            return remaining == 0 && current() ? values : nil
        }
    }

    private static func loadVideo(_ asset: PHAsset, deadline: DispatchTime,
                                  current: () -> Bool) -> AVAsset? {
        guard current(), DispatchTime.now() < deadline else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .automatic
        options.version = .current
        let results = CallbackResults<AVAsset>(count: 1)
        let manager = PHImageManager.default()
        let request = manager.requestAVAsset(forVideo: asset, options: options) { video, _, _ in
            results.complete(video)
        }
        guard let completed = results.wait(deadline: deadline, current: current) else {
            manager.cancelImageRequest(request)
            return nil
        }
        return completed.first
    }

    private static func videoFrames(in video: AVAsset, times: [Double], maxSide: CGFloat,
                                    tolerance: CMTime, deadline: DispatchTime,
                                    current: @escaping () -> Bool) -> [(seconds: Double, sampled: SampledPhoto)]? {
        guard !times.isEmpty, current(), DispatchTime.now() < deadline else { return nil }
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let results = CallbackResults<(seconds: Double, sampled: SampledPhoto)>(count: times.count)
        let values = times.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        generator.generateCGImagesAsynchronously(forTimes: values) { requested, image, actual, result, _ in
            if current(), DispatchTime.now() < deadline, result == .succeeded, let image,
               let sampled = Self.sample(UIImage(cgImage: image), maxSide: maxSide) {
                let actualSeconds = CMTimeGetSeconds(actual)
                let seconds = actualSeconds.isFinite && actualSeconds >= 0 ? actualSeconds : CMTimeGetSeconds(requested)
                results.complete((seconds, sampled))
            } else {
                results.complete(nil)
            }
        }
        guard let frames = results.wait(deadline: deadline, current: current) else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        return frames
    }

    private static func bestFrame(in video: AVAsset, times: [Double], placement: PictureHash.Placement,
                                  query: PictureHash.Pattern, side: Int, deadline: DispatchTime,
                                  current: @escaping () -> Bool) -> (score: Double, pattern: PictureHash.Pattern)? {
        let tolerance = CMTime(value: 1, timescale: 60)
        guard let frames = videoFrames(in: video, times: times, maxSide: 256, tolerance: tolerance,
                                      deadline: deadline, current: current) else { return nil }
        var best: (score: Double, pattern: PictureHash.Pattern)?
        for (_, sampled) in frames {
            guard current() else { return nil }
            let cells = PictureHash.cells(luma: sampled.luma, width: sampled.width, height: sampled.height,
                                          placement: placement, side: side)
            let pattern = PictureHash.pattern(cells, side: side)
            let score = PictureHash.similarity(query, pattern)
            if score > (best?.score ?? -2) { best = (score, pattern) }
        }
        return best
    }

    /// A sharper copy than the index keeps, for comparing a few close candidates.
    private static func render(_ asset: PHAsset, longSide: CGFloat,
                               manager: PHImageManager = .default(), timeout: Int = 2,
                               current: () -> Bool) -> SampledPhoto? {
        guard current() else { return nil }
        let result = CallbackResults<UIImage>(count: 1)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.version = .current
        let request = manager.requestImage(for: asset, targetSize: CGSize(width: longSide, height: longSide),
                                           contentMode: .aspectFit, options: options) { image, info in
            guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
            result.complete(image)
        }
        guard let completed = result.wait(deadline: .now() + .seconds(timeout), current: current) else {
            manager.cancelImageRequest(request)
            return nil
        }
        guard let image = completed.first else { return nil }
        return sample(image, maxSide: longSide)
    }

    private final class ThumbnailResults: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(offset: Int, photo: IndexedPhoto)] = []
        private var pixelBytes = 0
        private var sampledNew = 0

        var full: Bool {
            lock.lock()
            defer { lock.unlock() }
            return pixelBytes >= PhotoIndex.photoPixelBudget - 4096 || entries.count >= PhotoIndex.maxPhotoEntries
        }

        func insert(_ photo: IndexedPhoto, at offset: Int, sampled: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard entries.count < PhotoIndex.maxPhotoEntries,
                  photo.luma.count <= PhotoIndex.photoPixelBudget - pixelBytes else { return }
            entries.append((offset, photo))
            pixelBytes += photo.luma.count
            if sampled { sampledNew += 1 }
        }

        func finish() -> (entries: [IndexedPhoto], sampled: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (entries.sorted { $0.offset < $1.offset }.map(\.photo), sampledNew)
        }
    }

    // MARK: Opening with the saved index, then only what changed

    fileprivate static let tokenName = "photo-index-token.bin"

    private var videoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return videos.count
    }

    private static func readyStatus(photos: Int, videos: Int) -> String {
        "Photo library ready · \(itemCount(photos))" + (videos > 0 ? " · \(videos) \(videos == 1 ? "video" : "videos")" : "")
    }

    /// Shows the index saved last time at once, so matching works straight
    /// away; the check for changes follows. With limited access, only the
    /// items this iPhone still lets Porthole see.
    private func showSaved(access: PHAuthorizationStatus, generation: Int) {
        var saved = Self.loadPhotoList()
        guard !saved.isEmpty else { return }
        var movies = Self.loadVideoList()
        if access == .limited {
            let visible = Self.accessibleIDs(saved.map(\.localIdentifier))
            saved = saved.filter { visible.contains($0.localIdentifier) }
            movies = movies.filter { visible.contains($0.localIdentifier) }
        }
        lock.lock()
        let accepted = isCurrentLocked(generation) && photos.isEmpty && !saved.isEmpty
        if accepted {
            photos = saved
            videos = movies
            videoTotal = movies.count
            photosGeneration += 1
            fitKey = ""
            fitCells.removeAll()
        }
        lock.unlock()
        guard accepted else { return }
        let count = saved.count, videoCount = movies.count
        DispatchQueue.main.async {
            guard self.isCurrent(generation) else { return }
            self.ready = true
            self.status = Self.readyStatus(photos: count, videos: videoCount)
        }
    }

    private static func accessibleIDs(_ ids: [String]) -> Set<String> {
        var visible = Set<String>()
        var start = 0
        while start < ids.count {
            let end = min(ids.count, start + 2000)
            PHAsset.fetchAssets(withLocalIdentifiers: Array(ids[start..<end]), options: nil)
                .enumerateObjects { asset, _, _ in visible.insert(asset.localIdentifier) }
            start = end
        }
        return visible
    }

    private static func loadToken() -> PHPersistentChangeToken? {
        guard let url = cacheURL(tokenName), let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private func saveToken(_ token: PHPersistentChangeToken, generation: Int) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        writeCache(Self.tokenName, generation: generation) { writer in try writer.append(Array(data)) }
    }

    private struct LibraryChanges {
        var changed = Set<String>()
        var deleted = Set<String>()
    }

    /// What iOS says changed in the library since the token, in order. Nil
    /// when iOS no longer has that history (then a full pass).
    private static func changes(since token: PHPersistentChangeToken) -> LibraryChanges? {
        guard let result = try? PHPhotoLibrary.shared().fetchPersistentChanges(since: token) else { return nil }
        var found = LibraryChanges()
        for change in result {
            guard let details = try? change.changeDetails(for: PHObjectType.asset) else { return nil }
            for id in details.insertedLocalIdentifiers.union(details.updatedLocalIdentifiers) {
                found.changed.insert(id)
                found.deleted.remove(id)
            }
            for id in details.deletedLocalIdentifiers {
                found.deleted.insert(id)
                found.changed.remove(id)
            }
        }
        return found
    }

    /// Reads only the new and edited items and drops deleted ones. False
    /// when so much changed that a full pass is quicker.
    private func applyChanges(_ changes: LibraryChanges, generation: Int, token: PHPersistentChangeToken) -> Bool {
        guard changes.changed.count <= 400 else { return false }
        lock.lock()
        guard isCurrentLocked(generation), !photos.isEmpty else {
            lock.unlock()
            return false
        }
        var nextPhotos = photos
        var nextVideos = videos
        lock.unlock()
        guard !changes.changed.isEmpty || !changes.deleted.isEmpty else {
            saveToken(token, generation: generation)
            return true
        }
        let gone = changes.deleted.union(changes.changed)
        nextPhotos.removeAll { gone.contains($0.localIdentifier) }
        nextVideos.removeAll { gone.contains($0.localIdentifier) }
        let current = { self.isCurrent(generation) }
        var newPhotos: [IndexedPhoto] = []
        var newVideos: [VideoEntry] = []
        if !changes.changed.isEmpty {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(changes.changed), options: options)
            var stopped = false
            assets.enumerateObjects { asset, _, stop in
                guard current(), asset.mediaType == .image || asset.mediaType == .video,
                      asset.pixelWidth >= 2, asset.pixelHeight >= 2 else {
                    if !current() { stopped = true; stop.pointee = true }
                    return
                }
                let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
                if let thumbnail = Self.render(asset, longSide: 64, timeout: 5, current: current) {
                    newPhotos.append(IndexedPhoto(luma: thumbnail.luma, gridW: thumbnail.width, gridH: thumbnail.height,
                                                  localIdentifier: asset.localIdentifier, modified: modified))
                }
                if asset.mediaType == .video,
                   let entry = autoreleasepool(invoking: { Self.sampleVideo(asset, modified: modified, current: current) }) {
                    newVideos.append(entry)
                }
            }
            if stopped { return false }
        }
        // New items are the newest: they go first, where matching looks first.
        nextPhotos = Array((newPhotos + nextPhotos).prefix(Self.maxPhotoEntries))
        nextVideos = Array((newVideos + nextVideos).prefix(Self.maxVideoEntries))
        lock.lock()
        let accepted = isCurrentLocked(generation)
        if accepted {
            photos = nextPhotos
            videos = nextVideos
            videoTotal = nextVideos.count
            photosGeneration += 1
            fitKey = ""
            fitCells.removeAll()
        }
        let movieGeneration = videoGeneration
        lock.unlock()
        guard accepted else { return false }
        savePhotoCache(nextPhotos, generation: generation)
        saveVideoCache(nextVideos, generation: generation, movieGeneration: movieGeneration)
        saveToken(token, generation: generation)
        let count = nextPhotos.count, videoCount = nextVideos.count
        DispatchQueue.main.async {
            guard self.isCurrent(generation) else { return }
            self.ready = true
            self.status = Self.readyStatus(photos: count, videos: videoCount)
        }
        return true
    }

    private func index(generation: Int, access: PHAuthorizationStatus, diskCache: Bool) {
        // Taken first, so anything that changes while this runs is caught next time.
        let startToken = PHPhotoLibrary.shared().currentChangeToken
        lock.lock()
        let empty = photos.isEmpty
        lock.unlock()
        if diskCache, empty { showSaved(access: access, generation: generation) }
        // With full access, iOS says what changed since the saved index: only
        // that is read. Limited access, no saved index, or too much changed:
        // a full pass, which still reuses every item that didn't change.
        if diskCache, access == .authorized, let token = Self.loadToken(),
           let changes = Self.changes(since: token),
           applyChanges(changes, generation: generation, token: startToken) {
            DispatchQueue.main.async { self.finishIndex() }
            return
        }
        lock.lock()
        guard isCurrentLocked(generation) else {
            lock.unlock()
            DispatchQueue.main.async { self.finishIndex() }
            return
        }
        var previous = Dictionary(photos.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { _, new in new })
        videoGeneration += 1
        let movieGeneration = videoGeneration
        lock.unlock()
        if diskCache, previous.isEmpty { previous = Self.loadPhotoCache() }

        let fetch = PHFetchOptions()
        fetch.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        fetch.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: fetch)
        let total = assets.count
        let results = ThumbnailResults()
        let inFlight = DispatchSemaphore(value: 16)
        let group = DispatchGroup()
        let manager = PHCachingImageManager()
        let current = { self.isCurrent(generation) }
        for n in 0..<min(total, Self.maxPhotoEntries) {
            guard current(), !results.full else { break }

            let asset = assets.object(at: n)
            guard asset.pixelWidth >= 2, asset.pixelHeight >= 2 else { continue }
            let id = asset.localIdentifier
            let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
            if let old = previous[id], old.modified == modified {
                results.insert(old, at: n, sampled: false)
                continue
            }
            inFlight.wait()
            guard current() else { inFlight.signal(); break }
            group.enter()
            sampleQueue.async {
                defer { inFlight.signal(); group.leave() }
                guard let thumbnail = Self.render(asset, longSide: 64, manager: manager, timeout: 5, current: current),
                      current() else { return }
                results.insert(IndexedPhoto(luma: thumbnail.luma, gridW: thumbnail.width, gridH: thumbnail.height,
                                            localIdentifier: id, modified: modified), at: n, sampled: true)
            }
        }
        let oldIDs = Set(previous.keys)
        group.notify(queue: indexQueue) {
            let (finished, sampledNew) = results.finish()
            if diskCache, self.isCurrent(generation),
               sampledNew > 0 || Set(finished.map(\.localIdentifier)) != oldIDs {
                self.savePhotoCache(finished, generation: generation)
            }
            if diskCache { self.saveToken(startToken, generation: generation) }
            DispatchQueue.main.async {
                self.lock.lock()
                let accepted = self.isCurrentLocked(generation)
                if accepted {
                    self.photos = finished
                    self.photosGeneration += 1
                    self.fitKey = ""
                    self.fitCells.removeAll()
                }
                self.lock.unlock()
                if accepted {
                    self.ready = true
                    self.status = total == 0 ? "No accessible media in the photo library"
                        : Self.readyStatus(photos: finished.count, videos: self.videoCount)
                    self.indexVideos(photoCount: finished.count, generation: generation,
                                     movieGeneration: movieGeneration, diskCache: diskCache)
                }
                self.finishIndex()
            }
        }
    }

    private func finishIndex() {
        indexing = false
        if refreshPending {
            refreshPending = false
            let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            noteAccess(access)
            if canAccessLibrary { requestAccessAndIndex(refresh: true) }
        }
    }

    private func indexVideos(photoCount: Int, generation: Int, movieGeneration: Int, diskCache: Bool) {
        let current = {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.isCurrentLocked(generation) && self.videoGeneration == movieGeneration
        }
        videoQueue.async {
            guard current() else { return }
            let fetch = PHFetchOptions()
            fetch.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
            fetch.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: fetch)
            let total = assets.count
            self.lock.lock()
            var cache = Dictionary(self.videos.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { _, new in new })
            self.lock.unlock()
            if diskCache, cache.isEmpty { cache = Self.loadVideoCache() }
            // Progress is shown only the first time; after that the list in
            // use stays whole until the updated one replaces it.
            let firstTime = cache.isEmpty
            let decodeUntil = DispatchTime.now() + .seconds(90)
            var built: [VideoEntry] = []
            var skipped = 0
            var pixels = 0
            var lastProgress = 0
            var sampledNew = false

            func publish() -> Bool {
                self.lock.lock()
                let accepted = self.isCurrentLocked(generation) && self.videoGeneration == movieGeneration
                if accepted {
                    self.videos = built
                    self.videoTotal = total
                    self.videoSkipped = skipped
                }
                self.lock.unlock()
                let count = built.count
                let done = built.count >= min(total, Self.maxVideoEntries)
                DispatchQueue.main.async {
                    guard accepted, current() else { return }
                    self.status = firstTime && !done
                        ? "Library ready · \(Self.itemCount(photoCount)) · \(count) of \(total) videos analyzed"
                        : Self.readyStatus(photos: photoCount, videos: count)
                }
                return accepted
            }

            for n in 0..<min(total, Self.maxVideoEntries) {
                guard current(), pixels < Self.videoPixelBudget else { break }
                let asset = assets.object(at: n)
                let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
                let entry: VideoEntry?
                if let old = cache[asset.localIdentifier], old.modified == modified {
                    entry = old
                } else if DispatchTime.now() < decodeUntil {
                    entry = autoreleasepool { Self.sampleVideo(asset, modified: modified, current: current) }
                } else {
                    continue
                }
                if let entry {
                    let bytes = entry.frames.count * PictureHash.videoSide * PictureHash.videoSide
                    guard bytes <= Self.videoPixelBudget - pixels else { break }
                    built.append(entry)
                    pixels += bytes
                    if cache[asset.localIdentifier]?.modified != modified { sampledNew = true }
                } else {
                    skipped += 1
                }
                if firstTime, built.count - lastProgress >= 64 {
                    lastProgress = built.count
                    guard publish() else { return }
                }
            }
            guard publish() else { return }
            if diskCache, sampledNew || Set(built.map(\.localIdentifier)) != Set(cache.keys) {
                self.saveVideoCache(built, generation: generation, movieGeneration: movieGeneration)
            }
        }
    }

    private static func sampleVideo(_ asset: PHAsset, modified: Double,
                                    current: @escaping () -> Bool) -> VideoEntry? {
        let deadline = DispatchTime.now() + .seconds(6)
        guard let video = loadVideo(asset, deadline: min(deadline, .now() + .seconds(2)), current: current) else { return nil }
        let duration = asset.duration
        guard duration.isFinite, duration > 0, duration < Double(Int.max / 1200) else { return nil }
        let step = max(1.0, duration / Double(PictureHash.videoFramesMax))
        let times = (0..<PictureHash.videoFramesMax).map { Double($0) * step }.filter { $0 < duration }
        let tolerance = CMTime(seconds: min(step / 2, 1.0), preferredTimescale: 600)
        guard let sampledFrames = videoFrames(in: video, times: times, maxSide: 64, tolerance: tolerance,
                                              deadline: deadline, current: current), let first = sampledFrames.first else { return nil }
        var seen = Set<Double>()
        let frames: [VideoEntry.Frame] = sampledFrames.compactMap { seconds, photo in
            guard seconds >= 0, seconds < duration, seen.insert(seconds).inserted else { return nil }
            let whole = PictureHash.Crop(x: 0, y: 0, w: photo.width, h: photo.height)
            let cells = PictureHash.thumb(luma: photo.luma, width: photo.width, crop: whole, side: PictureHash.videoSide)
            return VideoEntry.Frame(seconds: seconds, pixels: cells.map { UInt8(min(255, max(0, $0.rounded()))) })
        }.sorted { $0.seconds < $1.seconds }
        guard !frames.isEmpty else { return nil }
        let aspect = Double(first.sampled.width) / Double(first.sampled.height)
        return VideoEntry(localIdentifier: asset.localIdentifier, modified: modified, aspect: aspect, frames: frames)
    }

    private static func cacheURL(_ name: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(name)
    }

    private static func removeLegacyCaches() {
        let files = FileManager.default
        if let directory = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            for name in ["photo-index-v1.bin", "video-frames-v1.bin"] {
                try? files.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        if let directory = files.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let entries = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for item in entries where item.lastPathComponent.hasPrefix(".porthole-index-") {
                try? files.removeItem(at: item)
            }
        }
    }

    private struct CacheReader {
        let data: Data
        var offset = 4

        init?(url: URL?, magic: String, maximumBytes: Int) {
            guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  (8...maximumBytes).contains(size), let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
                  bytes.count == size, bytes.prefix(4).elementsEqual(magic.utf8) else { return nil }
            data = bytes
        }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= data.count - offset else { return nil }
            defer { offset += count }
            return Array(data[offset..<(offset + count)])
        }

        mutating func number<T>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard size <= data.count - offset else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
    }

    private struct CacheWriter {
        let handle: FileHandle
        var buffer = Data()

        mutating func number<T>(_ value: T) {
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        }

        mutating func append(_ bytes: [UInt8]) throws {
            buffer.append(contentsOf: bytes)
            if buffer.count >= 64 * 1024 { try flush() }
        }

        mutating func flush() throws {
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func writeCache(_ name: String, generation: Int, movieGeneration: Int? = nil,
                            build: (inout CacheWriter) throws -> Void) {
        guard isCurrent(generation), let url = Self.cacheURL(name) else { return }
        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".porthole-index-\(UUID()).tmp")
        defer { try? files.removeItem(at: temp) }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            guard files.createFile(atPath: temp.path, contents: nil,
                                   attributes: [.protectionKey: FileProtectionType.complete]) else { return }
            let handle = try FileHandle(forWritingTo: temp)
            do {
                var writer = CacheWriter(handle: handle)
                try build(&writer)
                try writer.flush()
                try handle.close()
            } catch {
                try? handle.close()
                return
            }
            lock.lock()
            defer { lock.unlock() }
            guard isCurrentLocked(generation), libraryAccess == .authorized || libraryAccess == .limited,
                  movieGeneration.map({ $0 == videoGeneration }) ?? true else { return }
            if files.fileExists(atPath: url.path) {
                _ = try files.replaceItemAt(url, withItemAt: temp)
            } else {
                try files.moveItem(at: temp, to: url)
            }
        } catch {
            // A cache write is optional. Never replace the last valid index
            // with a partially generated file.
        }
    }

    private func savePhotoCache(_ entries: [IndexedPhoto], generation: Int) {
        let valid = entries.filter { $0.localIdentifier.utf8.count <= 1024 }
        writeCache("photo-index-v2.bin", generation: generation) { writer in
            try writer.append(Array("PHI2".utf8))
            writer.number(UInt32(valid.count))
            for (index, photo) in valid.enumerated() {
                if index.isMultiple(of: 128), !isCurrent(generation) { throw CancellationError() }
                let id = Array(photo.localIdentifier.utf8)
                writer.number(UInt16(id.count))
                try writer.append(id)
                writer.number(photo.modified)
                writer.number(UInt16(photo.gridW))
                writer.number(UInt16(photo.gridH))
                try writer.append(photo.luma)
            }
        }
    }

    private static func loadPhotoCache() -> [String: IndexedPhoto] {
        Dictionary(loadPhotoList().map { ($0.localIdentifier, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// The saved index, newest first, as it was written.
    private static func loadPhotoList() -> [IndexedPhoto] {
        guard var reader = CacheReader(url: cacheURL("photo-index-v2.bin"), magic: "PHI2",
                                       maximumBytes: photoPixelBudget + 96 * 1024 * 1024),
              let count = reader.number(UInt32.self), count <= maxPhotoEntries else { return [] }
        var result: [IndexedPhoto] = []
        var pixels = 0
        for _ in 0..<count {
            guard let idLength = reader.number(UInt16.self), (1...1024).contains(idLength),
                  let idBytes = reader.take(Int(idLength)), let id = String(bytes: idBytes, encoding: .utf8),
                  let modified = reader.number(Double.self), modified.isFinite,
                  let width = reader.number(UInt16.self), (2...64).contains(width),
                  let height = reader.number(UInt16.self), (2...64).contains(height) else { return [] }
            let bytes = Int(width) * Int(height)
            guard bytes <= photoPixelBudget - pixels, let luma = reader.take(bytes) else { return [] }
            result.append(IndexedPhoto(luma: luma, gridW: Int(width), gridH: Int(height), localIdentifier: id, modified: modified))
            pixels += bytes
        }
        return reader.offset == reader.data.count ? result : []
    }

    private func saveVideoCache(_ entries: [VideoEntry], generation: Int, movieGeneration: Int) {
        let valid = entries.filter { $0.localIdentifier.utf8.count <= 1024 }
        writeCache("video-frames-v2.bin", generation: generation, movieGeneration: movieGeneration) { writer in
            try writer.append(Array("PVF2".utf8))
            writer.number(UInt32(valid.count))
            for (index, entry) in valid.enumerated() {
                if index.isMultiple(of: 64) {
                    lock.lock()
                    let current = isCurrentLocked(generation) && self.videoGeneration == movieGeneration
                    lock.unlock()
                    guard current else { throw CancellationError() }
                }
                let id = Array(entry.localIdentifier.utf8)
                writer.number(UInt16(id.count))
                try writer.append(id)
                writer.number(entry.modified)
                writer.number(entry.aspect)
                writer.number(UInt16(entry.frames.count))
                for frame in entry.frames {
                    writer.number(frame.seconds)
                    try writer.append(frame.pixels)
                }
            }
        }
    }

    private static func loadVideoCache() -> [String: VideoEntry] {
        Dictionary(loadVideoList().map { ($0.localIdentifier, $0) }, uniquingKeysWith: { _, new in new })
    }

    private static func loadVideoList() -> [VideoEntry] {
        guard var reader = CacheReader(url: cacheURL("video-frames-v2.bin"), magic: "PVF2",
                                       maximumBytes: videoPixelBudget + 24 * 1024 * 1024),
              let count = reader.number(UInt32.self), count <= maxVideoEntries else { return [] }
        let cells = PictureHash.videoSide * PictureHash.videoSide
        var result: [VideoEntry] = []
        var pixels = 0
        for _ in 0..<count {
            guard let idLength = reader.number(UInt16.self), (1...1024).contains(idLength),
                  let idBytes = reader.take(Int(idLength)), let id = String(bytes: idBytes, encoding: .utf8),
                  let modified = reader.number(Double.self), modified.isFinite,
                  let aspect = reader.number(Double.self), aspect.isFinite, aspect > 0,
                  let frameCount = reader.number(UInt16.self), (1...PictureHash.videoFramesMax).contains(Int(frameCount)),
                  Int(frameCount) * cells <= videoPixelBudget - pixels else { return [] }
            var frames: [VideoEntry.Frame] = []
            for _ in 0..<frameCount {
                guard let seconds = reader.number(Double.self), seconds.isFinite, seconds >= 0,
                      seconds >= (frames.last?.seconds ?? 0), let frame = reader.take(cells) else { return [] }
                frames.append(VideoEntry.Frame(seconds: seconds, pixels: frame))
            }
            result.append(VideoEntry(localIdentifier: id, modified: modified, aspect: aspect, frames: frames))
            pixels += Int(frameCount) * cells
        }
        return reader.offset == reader.data.count ? result : []
    }

    private struct SampledPhoto {
        var luma: [UInt8]
        var width: Int
        var height: Int
    }

    /// Upright luma, top row first, same orientation the PC hashes from the mirror.
    private static func sample(_ image: UIImage, maxSide: CGFloat) -> SampledPhoto? {
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let width = max(2, Int((size.width * scale).rounded()))
        let height = max(2, Int((size.height * scale).rounded()))
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
