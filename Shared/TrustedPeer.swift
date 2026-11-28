import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct TrustedPeer: Codable, Equatable {
    let host: String
    let name: String
    let fingerprint: String
    let id: UUID
    var resumable = false
    var channelTicket: String?
    // Legacy saved records already have an ID. Preserve it when upgrading.
    var pairingID: UUID?
    var inboxVersion: Int?
    var broadcastVersion: Int?

    var stableID: UUID { pairingID ?? id }
    var screenProtocolVersion: Int { min(max(broadcastVersion ?? 1, 1), 4) }
    /// 4: the PC takes the checksum after the file, so sending starts at once.
    var receiveVersion: Int { (inboxVersion ?? 0) >= 4 ? 4 : inboxVersion == 3 ? 3 : resumable ? 2 : 1 }
    var credentialProfile: String { "\(stableID.uuidString.lowercased())/\(fingerprint)" }

    /// The PC's own name, exactly as it is: "UNKNOWN", "-" or blank-looking
    /// characters included. Only an empty value or a bare IP address (which
    /// came from the address field, not a name) is not a name.
    static func computerName(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv4 = in_addr()
        guard inet_pton(AF_INET, trimmed, &ipv4) != 1, !isIPv6(trimmed) else { return nil }
        return trimmed.isEmpty ? value : trimmed
    }

    func samePairing(as other: TrustedPeer) -> Bool {
        stableID == other.stableID && fingerprint == other.fingerprint
    }

    func newSession(host: String) -> TrustedPeer {
        TrustedPeer(host: host, name: name, fingerprint: fingerprint, id: UUID(), pairingID: stableID)
    }

    func reached(at host: String) -> TrustedPeer {
        var peer = TrustedPeer(host: host, name: name == self.host ? host : name,
                               fingerprint: fingerprint, id: id, pairingID: stableID)
        peer.resumable = resumable
        peer.channelTicket = channelTicket
        peer.inboxVersion = inboxVersion
        peer.broadcastVersion = broadcastVersion
        return peer
    }

    var remembered: TrustedPeer {
        TrustedPeer(host: host, name: name, fingerprint: fingerprint, id: stableID, pairingID: stableID)
    }

    static func pairingHost(_ rawAddress: String) -> String? {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty, address.utf8.count <= 270, !address.utf8.contains(0) else { return nil }
        // Unbracketed IPv6 is a bare address, even when its final group is numeric.
        if validHost(address) { return address }
        if address.hasPrefix("["), let end = address.firstIndex(of: "]") {
            let host = String(address[address.index(after: address.startIndex)..<end])
            let suffix = address[address.index(after: end)...]
            guard isIPv6(host), suffix.isEmpty || suffix == ":47731" else { return nil }
            return host
        }
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "47731", validHost(String(parts[0])) else { return nil }
        return String(parts[0])
    }

    private static func isIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, host, &address) == 1
    }

    static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, !host.utf8.contains(0) else { return false }
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 || isIPv6(host) { return true }
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") &&
                $0.unicodeScalars.allSatisfy(ascii.contains)
        }
    }

    static func normalizeFingerprint(_ input: String) -> String? {
        let digits = input.filter { !$0.isWhitespace && $0 != ":" }.lowercased()
        guard digits.utf8.count == 64, digits.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return digits
    }

    static func isChannelTicket(_ input: String) -> Bool {
        input.utf8.count == 64 && input.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum BroadcastPhase: String, Codable { case connecting, live, waitingForFrames, reconnecting, deliveryStopped, ended, failed }

/// Where the shared app's sound plays while sharing. The raw values are the
/// PC's protocol words.
enum SoundMode: String, Codable, CaseIterable, Identifiable {
    case pc, both, iPhone = "iphone"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pc: return "PC"
        case .both: return "Both"
        case .iPhone: return "iPhone"
        }
    }
    var help: String {
        switch self {
        case .pc: return "iPhone is muted. Its volume buttons control the PC."
        case .both: return "Plays on iPhone and PC."
        case .iPhone: return "Plays on iPhone only."
        }
    }
}

struct PairedChannelAuthorization: Codable {
    let pairingID: UUID
    let fingerprint: String
    let ticket: String

    init?(peer: TrustedPeer, ticket: String) {
        guard TrustedPeer.isChannelTicket(ticket) else { return nil }
        pairingID = peer.stableID
        fingerprint = peer.fingerprint
        self.ticket = ticket
    }

    func connectionPeer(for current: TrustedPeer) -> TrustedPeer? {
        guard current.stableID == pairingID, current.fingerprint == fingerprint,
              TrustedPeer.isChannelTicket(ticket) else { return nil }
        var destination = current
        destination.channelTicket = ticket
        return destination
    }
}

struct TrustedBroadcastStatus: Codable, Equatable {
    let peerID: UUID?
    let phase: BroadcastPhase
    let message: String?
    let updatedAt: Date
    var audioSent: Bool?
}

enum TrustedPeerStore {
    static var containerURL: URL? { PortholeAppGroup.containerURL }
    static var available: Bool { containerURL != nil }

    private static var directory: URL? { containerURL?.appendingPathComponent("Pairing", isDirectory: true) }

    static func load() -> TrustedPeer? { read("peer.json") }
    @discardableResult static func save(_ peer: TrustedPeer) -> Bool { write(peer, "peer.json") }
    static func clear() {
        remove("peer.json")
        remove("file-share.json")
        remove("screen-share.json")
        remove("broadcast-stop.json")
    }

    static func saveFileShareTicket(_ ticket: String, for peer: TrustedPeer) {
        guard load()?.id == peer.id, let authorization = PairedChannelAuthorization(peer: peer, ticket: ticket) else { return }
        write(authorization, "file-share.json")
    }

    static func fileSharePeer(matching reviewed: TrustedPeer) -> TrustedPeer? {
        guard let current = load(), current.samePairing(as: reviewed) else { return nil }
        let authorization: PairedChannelAuthorization? = read("file-share.json")
        if var destination = authorization?.connectionPeer(for: current) {
            destination.resumable = true
            destination.inboxVersion = max(3, current.inboxVersion ?? 3)
            return destination
        }
        return current.resumable && current.channelTicket.map(TrustedPeer.isChannelTicket) == true ? current : nil
    }

    static func saveScreenTicket(_ ticket: String, for peer: TrustedPeer) {
        guard load()?.id == peer.id, let authorization = PairedChannelAuthorization(peer: peer, ticket: ticket) else { return }
        write(authorization, "screen-share.json")
    }

    static func broadcastPeer(matching reviewed: TrustedPeer) -> TrustedPeer? {
        guard let current = load(), current.samePairing(as: reviewed) else { return nil }
        let authorization: PairedChannelAuthorization? = read("screen-share.json")
        if var destination = authorization?.connectionPeer(for: current) {
            destination.broadcastVersion = current.broadcastVersion ?? 2
            return destination
        }
        return current.channelTicket.map(TrustedPeer.isChannelTicket) == true ? current : nil
    }

    static func broadcastAudioEnabled() -> Bool {
        guard let url = directory?.appendingPathComponent("broadcast-audio.json") else { return false }
        do {
            return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: url))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return true
        } catch {
            return false
        }
    }
    static func setBroadcastAudioEnabled(_ enabled: Bool) -> Bool { write(enabled, "broadcast-audio.json") }

    /// Where the shared app's sound plays, chosen on the iPhone or the PC.
    /// Before a choice exists, the older app-audio setting decides.
    static func soundMode() -> SoundMode {
        if let mode: SoundMode = read("sound-mode.json") { return mode }
        return broadcastAudioEnabled() ? .both : .iPhone
    }

    /// "PC" and "Both" send the shared app's sound with the screen over Wi-Fi,
    /// which works with any PC; with "PC" the iPhone also holds its own volume
    /// at zero. With "iPhone" the sound stays here.
    @discardableResult static func setSoundMode(_ mode: SoundMode) -> Bool {
        write(mode, "sound-mode.json") && setBroadcastAudioEnabled(mode != .iPhone)
    }

    static func broadcastStatus() -> TrustedBroadcastStatus? { read("broadcast.json") }
    static func publishBroadcast(peer: TrustedPeer?, phase: BroadcastPhase, message: String? = nil,
                                 audioSent: Bool? = nil) {
        if let peer, load()?.samePairing(as: peer) != true { return }
        write(TrustedBroadcastStatus(peerID: peer?.stableID, phase: phase, message: message,
                                     updatedAt: Date(), audioSent: audioSent), "broadcast.json")
    }

    static func requestBroadcastStop(peer: TrustedPeer) -> Bool {
        guard load()?.samePairing(as: peer) == true else { return false }
        return write(peer.stableID, "broadcast-stop.json")
    }

    static func shouldStopBroadcast(peer: TrustedPeer) -> Bool {
        let requested: UUID? = read("broadcast-stop.json")
        return requested == peer.stableID
    }

    static func clearBroadcastStop(peer: TrustedPeer) {
        if load()?.samePairing(as: peer) == true { remove("broadcast-stop.json") }
    }

    private static func read<Value: Decodable>(_ name: String) -> Value? {
        guard let url = directory?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    @discardableResult private static func write<Value: Encodable>(_ value: Value, _ name: String) -> Bool {
        guard let url = directory?.appendingPathComponent(name), let data = try? JSONEncoder().encode(value) else { return false }
        do {
            #if os(iOS)
            var parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try parent.setResourceValues(values)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            return true
        } catch { return false }
    }

    private static func remove(_ name: String) {
        guard let url = directory?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
