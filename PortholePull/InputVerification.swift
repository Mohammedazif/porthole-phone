import Foundation

enum InputVerificationStatus: Equatable {
    case required
    case waiting
    case confirming
    case verified
    case failed(String)

    var inProgress: Bool { self == .waiting || self == .confirming }
}

struct InputVerificationAttempt {
    let id = UUID().uuidString.lowercased()
    private var digits: [UInt8] = []
    private var submitted = false

    static func acceptsKeypadUsage(_ usage: Int) -> Bool { (0x59...0x62).contains(usage) }

    mutating func acceptKeypadUsage(_ usage: Int) -> String? {
        guard !submitted, Self.acceptsKeypadUsage(usage) else { return nil }
        digits.append(usage == 0x62 ? 48 : UInt8(usage - 0x58) + 48)
        guard digits.count == 16 else { return nil }
        let proof = String(decoding: digits, as: UTF8.self)
        digits.removeAll()
        submitted = true
        return proof
    }
}
