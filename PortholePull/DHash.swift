import Foundation

enum PictureHash {
    static let matchMax = 10
    static let matchGap = 6
    static let aspectTol = 0.08

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

    static func pick(query: UInt64, queryAspect: Double, hashes: [UInt64], aspects: [Double]) -> Int? {
        var best = -1
        var bestDistance = 65
        var second = 65
        for index in hashes.indices {
            if queryAspect > 0, index < aspects.count, aspects[index] > 0 {
                let diff = abs(aspects[index] - queryAspect) / queryAspect
                if diff > aspectTol { continue }
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
        if best < 0 || bestDistance > matchMax { return nil }
        if second < bestDistance + matchGap { return nil }
        return best
    }

    private static func at(_ numer: Int, _ denom: Int, _ limit: Int) -> Int {
        if limit < 1 { return 0 }
        let value = numer / denom
        if value < 0 { return 0 }
        if value >= limit { return limit - 1 }
        return value
    }
}
