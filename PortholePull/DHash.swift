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
    static func thumb(luma: [UInt8], width: Int, crop c: Crop) -> [Double] {
        let n = thumbSide
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
    static func gradients(_ t: [Double]) -> [Double] {
        let n = thumbSide
        var g = [Double]()
        if t.count != n * n { return g }
        g.reserveCapacity(2 * n * (n - 1))
        for r in 0..<n {
            for c in 0..<(n - 1) {
                g.append(t[r * n + c + 1] - t[r * n + c])
            }
        }
        for r in 0..<(n - 1) {
            for c in 0..<n {
                g.append(t[(r + 1) * n + c] - t[r * n + c])
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
        let n = thumbSide * thumbSide
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
