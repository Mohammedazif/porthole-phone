import CryptoKit
import Foundation
import Network
import Security

enum TrustedPeerTransport {
    private static let trustQueue = DispatchQueue(label: "porthole.identity")

    /// The fingerprint comes from the desktop QR or an explicit manual entry.
    /// A pinned leaf identifies this peer even on a local IP or with a self-signed cert.
    /// While the screen is shared, files go as background traffic (47733) so
    /// the shared screen (interactive video) and the controls keep the Wi-Fi
    /// first.
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
        switch port {
        case 47733:
            // Background only while the screen is shared: then the screen and
            // the controls go first. Otherwise a file goes at full speed.
            let phase = TrustedPeerStore.broadcastStatus()?.phase
            let sharing = phase == .live || phase == .waitingForFrames || phase == .connecting
            parameters.serviceClass = sharing ? .background : .bestEffort
        case 47732: parameters.serviceClass = .interactiveVideo
        default: parameters.serviceClass = .responsiveData
        }
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

/// Deletes on the PC what arrived of files the person cancelled here, so
/// nothing continues them later. Only a PC that takes the checksum after
/// the file (inbox 4) knows DROP; an older one keeps the part.
enum TransferDrop {
    static func send(_ ids: [UUID], to peer: TrustedPeer) {
        guard !ids.isEmpty, ids.count <= 500 else { return }
        let queue = DispatchQueue(label: "porthole.transfer.drop")
        let connection = TrustedPeerTransport.connection(to: peer, port: 47733)
        let lines = ids.map { "DROP \($0.uuidString.replacingOccurrences(of: "-", with: "").lowercased())\n" }.joined()
        var received = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
                if let data { received.append(data) }
                // The PC answers DROPPED for each, then BYE.
                if done || error != nil || String(decoding: received, as: UTF8.self).contains("BYE\n") {
                    connection.cancel()
                } else {
                    read()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            TrustedPeerTransport.authenticate(connection: connection, peer: peer) { authorized in
                guard authorized else { connection.cancel(); return }
                connection.send(content: Data("PSHR 4 \(ids.count)\n\(lines)DONE\n".utf8),
                                completion: .contentProcessed { _ in read() })
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { connection.cancel() }
    }
}
