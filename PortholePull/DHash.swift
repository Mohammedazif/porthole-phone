import Foundation

enum PictureHash {
    static let matchMax = 20
    static let matchGap = 6
    static let aspectTol = 0.18

    /// Burst shots share a dHash. The PC also sends a 32 x 32 picture; its gradients
    /// separate them (same shot near 0.98, the next frame of a burst near 0.6).
    static let thumbSide = 32
    static let candidateBits = 28
    static let gradientMin = 0.75
    static let gradientGap = 0.10

    /// Videos keep up to videoFramesMax frames from across their length, each as
    /// videoSide x videoSide cells, so a video matches while it plays.
    static let videoSide = 16
    static let videoFramesMax = 24
    /// A video drag at 0.455 led every other video by 0.18; wrong videos scored 0.24 to 0.32.
    static let videoMin = 0.42
    static let videoGap = 0.15

    /// The PC also sends the picture at detailSide cells a side. It is compared only
    /// between the few closest candidates: two shots of a burst, two moments of a video.
    static let detailSide = 64
    /// After the closer look: a 64-cell copy of the picture on screen scores well above this.
    static let detailMin = 0.6
    /// Two library items whose own pictures agree this well are copies of one picture,
    /// such as a duplicate or a saved copy. Either is the picture; neither blocks the other.
    static let copyMin = 0.97

    /// How far the winner must lead the next different picture. A near-perfect score
    /// needs less: 0.962 against 0.894 was the right photo and used to be refused.
    static func requiredGap(_ top: Double) -> Double {
        if top >= 0.92 { return 0.04 }
        if top >= 0.85 { return 0.07 }
        return gradientGap
    }

    /// Gradients of a picture three ways: whole, without a margin on every side, and
    /// without the top and bottom bands. Photos draws its bars and a paused video its
    /// controls over those edges, so the best of the three is the fair comparison.
    struct Pattern {
        var parts: [[Double]]
    }

    static func pattern(_ cells: [Double], side n: Int) -> Pattern {
        guard n >= 8, cells.count == n * n else { return Pattern(parts: []) }
        let margin = n / 8
        let band = n / 5
        return Pattern(parts: [
            gradients(cells, side: n),
            region(cells, side: n, top: margin, bottom: margin, left: margin, right: margin),
            region(cells, side: n, top: band, bottom: band + n / 16, left: 0, right: 0),
        ])
    }

    static func similarity(_ a: Pattern, _ b: Pattern) -> Double {
        guard !a.parts.isEmpty, a.parts.count == b.parts.count else { return -1 }
        var best = -1.0
        for i in a.parts.indices {
            best = max(best, correlation(a.parts[i], b.parts[i]))
        }
        return best
    }

    /// Gradients of the cells left after cutting the given rows and columns away.
    static func region(_ cells: [Double], side n: Int, top: Int, bottom: Int, left: Int, right: Int) -> [Double] {
        let w = n - left - right
        let h = n - top - bottom
        guard w >= 2, h >= 2, cells.count == n * n else { return [] }
        var part = [Double]()
        part.reserveCapacity(w * h)
        for y in top..<(n - bottom) {
            part.append(contentsOf: cells[(y * n + left)..<(y * n + left + w)])
        }
        return gradients(part, width: w, height: h)
    }

    /// Times to decode around the coarse frames that came closest, covering the gap to
    /// the neighbouring coarse frames. Bounded, so a long movie stays quick.
    static func refinementTimes(duration: Double, frames: Int, anchors: [Int]) -> [Double] {
        guard duration.isFinite, duration > 0, frames > 0, !anchors.isEmpty else { return [] }
        let step = max(1.0, duration / Double(videoFramesMax))
        let radius = step / 2 + 0.6
        var ticks = Set<Int>()
        for anchor in anchors.prefix(2) where anchor >= 0 && anchor < frames {
            let center = Double(anchor) * step
            let lower = max(0, center - radius)
            let upper = min(duration - 0.05, center + radius)
            guard upper >= lower else { continue }
            let intervals = min(10, max(1, Int(ceil((upper - lower) / 0.25))))
            for index in 0...intervals {
                ticks.insert(Int(((lower + (upper - lower) * Double(index) / Double(intervals)) * 600).rounded()))
            }
        }
        return ticks.sorted().map { Double($0) / 600 }.filter { $0 >= 0 && $0 < duration }
    }

    /// A query against many small video frames, without building arrays per frame.
    /// Both halves are zero-mean and unit length, so a dot product is the correlation.
    struct FrameQuery {
        let side: Int
        private let grad: [Double]
        private let luma: [Double]

        init?(cells: [Double], side: Int) {
            guard side >= 2, cells.count == side * side else { return nil }
            guard let g = FrameQuery.unit(PictureHash.gradients(cells, side: side)),
                  let l = FrameQuery.unit(cells) else { return nil }
            self.side = side
            grad = g
            luma = l
        }

        private static func unit(_ v: [Double]) -> [Double]? {
            guard !v.isEmpty else { return nil }
            let mean = v.reduce(0, +) / Double(v.count)
            let centered = v.map { $0 - mean }
            let norm = centered.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { return nil }
            return centered.map { $0 / norm }
        }

        /// Gradient and plain-picture correlation with one frame of side x side bytes.
        func score(_ frame: [UInt8]) -> (grad: Double, luma: Double) {
            let n = side
            guard frame.count == n * n else { return (-1, -1) }
            return frame.withUnsafeBufferPointer { p in
                var s = 0.0, ss = 0.0, dot = 0.0
                var i = 0
                for r in 0..<n {
                    let row = r * n
                    for c in 0..<(n - 1) {
                        let v = Double(p[row + c + 1]) - Double(p[row + c])
                        s += v; ss += v * v; dot += grad[i] * v; i += 1
                    }
                }
                for r in 0..<(n - 1) {
                    for c in 0..<n {
                        let v = Double(p[(r + 1) * n + c]) - Double(p[r * n + c])
                        s += v; ss += v * v; dot += grad[i] * v; i += 1
                    }
                }
                let spread = ss - s * s / Double(i)
                let g = spread > 0 ? dot / spread.squareRoot() : 0
                var ls = 0.0, lss = 0.0, ldot = 0.0
                for k in 0..<(n * n) {
                    let v = Double(p[k])
                    ls += v; lss += v * v; ldot += luma[k] * v
                }
                let lspread = lss - ls * ls / Double(n * n)
                let l = lspread > 0 ? ldot / lspread.squareRoot() : 0
                return (g, l)
            }
        }
    }

    static func dhash(width: Int, height: Int, lumaAt: (Int, Int) -> UInt8) -> UInt64 {
        if width < 2 || height < 2 { return 0 }
        var hash: UInt64 = 0
        for row in 0..<8 {
            let y = at((row * 2 + 1) * height, 16, height)
            for col in 0..<8 {
                let x0 = at((col * 2 + 1) * width, 18, width)
                let x1 = at(((col + 1) * 2 + 1) * width, 18, width)
                if lumaAt(x0, y) > lumaAt(x1, y) {
                    hash |= UInt64(1) << (63 - (row * 8 + col))
                }
            }
        }
        return hash
    }

    static func luma(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        UInt8((Int(r) * 77 + Int(g) * 150 + Int(b) * 29) >> 8)
    }

    /// dHash of the centre of a full photo, cropped to the shape on screen.
    /// A library thumbnail is square; the camera file usually is not. Cropping
    /// both to the same shape is what makes those two pictures comparable.
    static func dhashCrop(luma: [UInt8], width: Int, height: Int, aspect: Double) -> UInt64 {
        if width < 2 || height < 2 || aspect < 0.05 || luma.count < width * height { return 0 }
        let c = crop(width: width, height: height, aspect: aspect)
        return dhash(width: c.w, height: c.h) { x, y in
            luma[(c.y + y) * width + (c.x + x)]
        }
    }

    struct Crop {
        var x: Int
        var y: Int
        var w: Int
        var h: Int
    }

    /// The centre of a full photo cut to the shape it has on screen.
    static func crop(width: Int, height: Int, aspect: Double) -> Crop {
        var c = Crop(x: 0, y: 0, w: width, h: height)
        if width < 2 || height < 2 || aspect < 0.05 { return c }
        let photo = Double(width) / Double(height)
        if photo > aspect {
            c.w = min(width, max(2, Int((Double(height) * aspect).rounded())))
            c.x = (width - c.w) / 2
        } else if photo < aspect {
            c.h = min(height, max(2, Int((Double(width) / aspect).rounded())))
            c.y = (height - c.h) / 2
        }
        return c
    }

    /// Box average into thumbSide x thumbSide cells. Cell bounds are the PC's:
    /// rows [r*h/n, max(that+1, (r+1)*h/n)), and the same for columns.
    static func thumb(luma: [UInt8], width: Int, crop c: Crop, side: Int = thumbSide) -> [Double] {
        let n = side
        var out = [Double](repeating: 0, count: n * n)
        if c.w < 1 || c.h < 1 || luma.count < (c.y + c.h - 1) * width + c.x + c.w { return out }
        for r in 0..<n {
            let y0 = r * c.h / n
            var y1 = (r + 1) * c.h / n
            if y1 <= y0 { y1 = y0 + 1 }
            for col in 0..<n {
                let x0 = col * c.w / n
                var x1 = (col + 1) * c.w / n
                if x1 <= x0 { x1 = x0 + 1 }
                var sum = 0
                for y in y0..<y1 {
                    let row = (c.y + y) * width + c.x
                    for x in x0..<x1 {
                        sum += Int(luma[row + x])
                    }
                }
                out[r * n + col] = Double(sum) / Double((y1 - y0) * (x1 - x0))
            }
        }
        return out
    }

    /// Horizontal then vertical neighbour differences of a thumb.
    static func gradients(_ t: [Double], side: Int = thumbSide) -> [Double] {
        gradients(t, width: side, height: side)
    }

    static func gradients(_ t: [Double], width w: Int, height h: Int) -> [Double] {
        var g = [Double]()
        if w < 2 || h < 2 || t.count != w * h { return g }
        g.reserveCapacity(2 * w * h - w - h)
        for r in 0..<h {
            for c in 0..<(w - 1) {
                g.append(t[r * w + c + 1] - t[r * w + c])
            }
        }
        for r in 0..<(h - 1) {
            for c in 0..<w {
                g.append(t[(r + 1) * w + c] - t[r * w + c])
            }
        }
        return g
    }

    /// Normalised correlation, so the video's brightness and contrast do not matter.
    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        if a.isEmpty || a.count != b.count { return 0 }
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        var ab = 0.0
        var aa = 0.0
        var bb = 0.0
        for i in a.indices {
            let x = a[i] - ma
            let y = b[i] - mb
            ab += x * y
            aa += x * x
            bb += y * y
        }
        if aa <= 0 || bb <= 0 { return 0 }
        return ab / (aa * bb).squareRoot()
    }

    /// A thumbSide thumb averaged down to side x side cells.
    static func shrink(_ t: [Double], to side: Int) -> [Double] {
        let n = thumbSide
        if t.count != n * n || side < 1 || n % side != 0 { return [] }
        let k = n / side
        var out = [Double](repeating: 0, count: side * side)
        for r in 0..<side {
            for c in 0..<side {
                var sum = 0.0
                for y in 0..<k {
                    for x in 0..<k {
                        sum += t[(r * k + y) * n + c * k + x]
                    }
                }
                out[r * side + c] = sum / Double(k * k)
            }
        }
        return out
    }

    /// Cells as two hex digits each, the same layout as the PC sends.
    static func hex(_ cells: [Double]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(cells.count * 2)
        for value in cells {
            let byte = Int(min(255, max(0, value.rounded())))
            out.append(digits[byte >> 4])
            out.append(digits[byte & 15])
        }
        return out
    }

    /// The fourth field of PULL: thumbSide squared bytes as hex.
    static func parseThumb(_ hex: Substring) -> [Double]? {
        parseCells(hex, side: thumbSide)
    }

    /// side squared bytes as hex, such as the fifth PULL field at detailSide.
    static func parseCells(_ hex: Substring, side: Int) -> [Double]? {
        let n = side * side
        let bytes = Array(hex.utf8)
        if bytes.count != n * 2 { return nil }
        var out = [Double]()
        out.reserveCapacity(n)
        var high: UInt8 = 0
        for (i, ch) in bytes.enumerated() {
            let v: UInt8
            switch ch {
            case 48...57: v = ch - 48
            case 97...102: v = ch - 87
            case 65...70: v = ch - 55
            default: return nil
            }
            if i % 2 == 0 {
                high = v
            } else {
                out.append(Double(high * 16 + v))
            }
        }
        return out
    }

    struct Pick {
        var index: Int?
        var closest = 65
    }

    static func pick(query: UInt64, queryAspect: Double, hashes: [UInt64], aspects: [Double]) -> Pick {
        var best = -1
        var bestDistance = 65
        var second = 65
        for index in hashes.indices {
            if queryAspect > 0, index < aspects.count, aspects[index] > 0,
               !aspectMatches(aspects[index], queryAspect) {
                continue
            }
            let distance = (query ^ hashes[index]).nonzeroBitCount
            if distance < bestDistance {
                second = bestDistance
                bestDistance = distance
                best = index
            } else if distance < second {
                second = distance
            }
        }
        guard best >= 0 else { return Pick() }
        let unique = bestDistance <= matchMax && second >= bestDistance + matchGap
        return Pick(index: unique ? best : nil, closest: bestDistance)
    }

    /// The camera file's stored shape can be the other way up from the screen.
    private static func aspectMatches(_ stored: Double, _ query: Double) -> Bool {
        if abs(stored - query) / query <= aspectTol { return true }
        let turned = 1 / query
        return abs(stored - turned) / turned <= aspectTol
    }

    private static func at(_ numer: Int, _ denom: Int, _ limit: Int) -> Int {
        if limit < 1 { return 0 }
        let value = numer / denom
        if value < 0 { return 0 }
        if value >= limit { return limit - 1 }
        return value
    }
}
