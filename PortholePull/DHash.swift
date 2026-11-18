import Foundation

enum PictureHash {
    static let matchMax = 20
    static let matchGap = 6
    static let aspectTol = 0.18

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
