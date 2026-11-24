import Foundation

enum SavedPCLAN {
    static func alternateAddresses(for host: String, localAddresses: [String]) -> [String] {
        guard let address = octets(host) else { return [] }
        let network = address.prefix(3)
        guard localAddresses.contains(where: { octets($0)?.prefix(3) == network }) else { return [] }
        let prefix = network.map(String.init).joined(separator: ".")
        let local = Set(localAddresses)
        return (1...253).flatMap { distance in [address[3] - distance, address[3] + distance] }
            .filter { (1...254).contains($0) }
            .map { "\(prefix).\($0)" }
            .filter { !local.contains($0) }
    }

    private static func octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0) }
        guard parts.count == 4, values.count == 4, values.allSatisfy({ (0...255).contains($0) }),
              values[0] != 127 else { return nil }
        return values
    }
}

#if os(iOS)
import Darwin
import Network

/// Uses the stored address first. Recovery accepts only the certificate from the original QR or manual pairing.
final class SavedPCConnection {
    enum Failure: Error { case unavailable, localNetworkDenied }
    typealias Destination = (peer: TrustedPeer, link: NWConnection)

    private let peer: TrustedPeer
    private let port: NWEndpoint.Port
    private let queue: DispatchQueue
    private let recoverAddress: Bool
    private var attempts: [UUID: NWConnection] = [:]
    private var addresses: ArraySlice<String> = []
    private var timeout: DispatchWorkItem?
    private var completion: ((Result<Destination, Failure>) -> Void)?
    private var lookingNearby = false

    init(peer: TrustedPeer, port: NWEndpoint.Port, queue: DispatchQueue, recoverAddress: Bool = true) {
        self.peer = peer
        self.port = port
        self.queue = queue
        self.recoverAddress = recoverAddress
    }

    func start(_ completion: @escaping (Result<Destination, Failure>) -> Void) {
        self.completion = completion
        attempt([peer.host], within: .seconds(3))
    }

    func cancel() {
        completion = nil
        clearAttempts()
    }

    private func clearAttempts() {
        timeout?.cancel()
        timeout = nil
        for link in attempts.values {
            link.stateUpdateHandler = nil
            link.cancel()
        }
        attempts.removeAll()
    }

    private func finish(_ result: Result<Destination, Failure>) {
        let callback = completion
        cancel()
        callback?(result)
    }

    private func nextBatch() {
        clearAttempts()
        guard recoverAddress else { finish(.failure(.unavailable)); return }
        if !lookingNearby {
            lookingNearby = true
            addresses = SavedPCLAN.alternateAddresses(for: peer.host,
                                                      localAddresses: Self.localIPv4Addresses())[...]
        }
        guard !addresses.isEmpty else { finish(.failure(.unavailable)); return }
        let batch = Array(addresses.prefix(32))
        addresses = addresses.dropFirst(batch.count)
        attempt(batch, within: .milliseconds(900))
    }

    private func attempt(_ hosts: [String], within limit: DispatchTimeInterval) {
        let timer = DispatchWorkItem { [weak self] in self?.nextBatch() }
        timeout = timer
        queue.asyncAfter(deadline: .now() + limit, execute: timer)
        for host in hosts {
            let id = UUID()
            let candidate = peer.reached(at: host)
            let link = TrustedPeerTransport.connection(to: candidate, port: port, wifiOnly: lookingNearby)
            attempts[id] = link
            link.stateUpdateHandler = { [weak self, weak link] state in
                guard let self, let link, self.attempts[id] === link else { return }
                switch state {
                case .ready:
                    self.attempts.removeValue(forKey: id)
                    link.stateUpdateHandler = nil
                    self.finish(.success((candidate, link)))
                case .waiting where link.currentPath?.unsatisfiedReason == .localNetworkDenied:
                    self.finish(.failure(.localNetworkDenied))
                case .failed, .cancelled:
                    self.attempts.removeValue(forKey: id)
                    link.stateUpdateHandler = nil
                    link.cancel()
                    if self.attempts.isEmpty { self.nextBatch() }
                default: break
                }
            }
            link.start(queue: queue)
        }
    }

    private static func localIPv4Addresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses: [String] = []
        for item in sequence(first: interfaces, next: { $0.pointee.ifa_next }) {
            let info = item.pointee
            guard info.ifa_flags & UInt32(IFF_UP) != 0, let address = info.ifa_addr,
                  address.pointee.sa_family == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: host))
            }
        }
        return addresses
    }
}
#endif
