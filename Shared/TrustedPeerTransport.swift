import CryptoKit
import Foundation
import Network
import Security

enum TrustedPeerTransport {
    private static let trustQueue = DispatchQueue(label: "porthole.identity")

    /// The fingerprint comes from the desktop QR or an explicit manual entry.
    /// A pinned leaf identifies this peer even on a local IP or with a self-signed cert.
    static func connection(to peer: TrustedPeer, port: NWEndpoint.Port, wifiOnly: Bool = false) -> NWConnection {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetNetworkFetchAllowed(reference, false)
            guard let chain = SecTrustCopyCertificateChain(reference) as? [SecCertificate], let leaf = chain.first,
                  let fingerprint = TrustedPeer.normalizeFingerprint(peer.fingerprint) else { complete(false); return }
            let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            let presented = digest.map { String(format: "%02x", $0) }.joined()
            complete(presented == fingerprint)
        }, trustQueue)
        let parameters = NWParameters(tls: options, tcp: .init())
        if wifiOnly { parameters.requiredInterfaceType = .wifi }
        return NWConnection(host: NWEndpoint.Host(peer.host), port: port, using: parameters)
    }

    /// Call once after TLS becomes ready, with the caller's connection deadline active.
    static func authenticate(connection: NWConnection, peer: TrustedPeer, completion: @escaping (Bool) -> Void) {
        guard let ticket = peer.channelTicket, TrustedPeer.isChannelTicket(ticket) else { completion(false); return }
        connection.send(content: Data("AUTH \(ticket)\n".utf8), completion: .contentProcessed { error in
            guard error == nil else { completion(false); return }
            connection.receive(minimumIncompleteLength: 3, maximumLength: 3) { data, _, complete, error in
                completion(error == nil && !complete && data == Data("OK\n".utf8))
            }
        })
    }
}
