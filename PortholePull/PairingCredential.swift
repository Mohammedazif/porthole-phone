import Foundation
import Security

enum PairingCredential {
    private static func query(_ profile: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Porthole companion pairing",
         kSecAttrAccount as String: profile]
    }

    static func load(_ profile: String) -> String? {
        var request = query(profile)
        request[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func getOrCreate(_ profile: String) -> String? {
        guard !profile.isEmpty else { return nil }
        if let key = load(profile) { return key }
        guard let key = randomKey() else { return nil }
        var request = query(profile)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        request[kSecValueData as String] = Data(key.utf8)
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { return load(profile) }
        return key
    }

    static func randomKey() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func save(_ value: String, for profile: String) -> Bool {
        let item = query(profile)
        let data = Data(value.utf8)
        let changed = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if changed == errSecSuccess { return true }
        guard changed == errSecItemNotFound else { return false }
        var request = item
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        request[kSecValueData as String] = data
        return SecItemAdd(request as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ profile: String) {
        SecItemDelete(query(profile) as CFDictionary)
    }
}

struct PendingPairing: Codable {
    private static let account = "pending-pairing"

    let peer: TrustedPeer
    let key: String
    private var code: String?
    let expiresAt: Date

    var activeCode: String? { Date() < expiresAt ? code : nil }

    static func load() -> PendingPairing? {
        guard let value = PairingCredential.load(account),
              var attempt = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)) else { return nil }
        if attempt.code != nil, attempt.activeCode == nil {
            attempt.code = nil
            _ = attempt.persist()
        }
        return attempt
    }

    static func prepare(_ peer: TrustedPeer, code: String) -> Bool {
        guard let key = PairingCredential.randomKey() else { return false }
        return Self(peer: peer.remembered, key: key, code: code,
                    expiresAt: Date().addingTimeInterval(600)).persist()
    }

    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return PairingCredential.save(String(decoding: data, as: UTF8.self), for: Self.account)
    }

    static func clear(for peer: TrustedPeer) {
        if load()?.peer.samePairing(as: peer) == true { PairingCredential.remove(account) }
        PairingCredential.remove("bootstrap/" + peer.credentialProfile)
        PairingCredential.remove("pending/" + peer.credentialProfile)
    }
}
