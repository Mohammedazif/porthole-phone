import Foundation
import Network
import Photos

final class PullClient: ObservableObject {
    @Published var status = "Not connected"
    @Published var address = ""
    @Published var code = ""
    private let queue = DispatchQueue(label: "porthole.pull")
    private var connection: NWConnection?
    private var buffer = Data()
    private var greeted = false
    private weak var index: PhotoIndex?

    func bind(index: PhotoIndex) {
        self.index = index
    }

    func connect() {
        let host = address.trimmingCharacters(in: .whitespaces)
        let token = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !host.isEmpty, token.count == 8 else {
            status = "Enter the PC address and the 8-character code"
            return
        }
        connection?.cancel()
        buffer.removeAll()
        greeted = false
        let link = NWConnection(host: NWEndpoint.Host(host), port: 47731, using: .tcp)
        connection = link
        link.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.status = "Connected"
                    self?.send("HELLO \(token)\n")
                    self?.receive()
                case .failed, .cancelled:
                    self?.status = "Disconnected"
                case .waiting:
                    self?.status = "Waiting for the PC. Allow Local Network if iOS asks."
                default:
                    break
                }
            }
        }
        link.start(queue: queue)
        status = "Connecting"
    }

    private func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if error != nil || complete {
                DispatchQueue.main.async { self.status = "Disconnected" }
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            handle(text)
        }
    }

    private func handle(_ line: String) {
        if line == "OK" {
            greeted = true
            DispatchQueue.main.async { self.status = "Connected. Leave this app open." }
            return
        }
        guard greeted, line.hasPrefix("PULL ") else { return }
        let parts = line.split(separator: " ")
        guard parts.count == 3, let hash = UInt64(parts[1], radix: 16), let aspect = Double(parts[2]) else {
            send("MISS\n")
            return
        }
        guard let index, index.ready, let asset = index.match(hash: hash, aspect: aspect) else {
            send("MISS\n")
            DispatchQueue.main.async { self.status = "No single photo matched the window" }
            return
        }
        export(asset)
    }

    private func export(_ asset: PHAsset) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto }) else {
            send("MISS\n")
            return
        }
        guard let name = safeName(resource.originalFilename) else {
            send("MISS\n")
            return
        }
        var body = Data()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
            body.append(chunk)
        } completionHandler: { [weak self] error in
            guard let self else { return }
            if error != nil || body.isEmpty || body.count > 200 * 1024 * 1024 {
                self.send("MISS\n")
                DispatchQueue.main.async { self.status = "Could not read that photo" }
                return
            }
            self.send("FILE \(body.count) \(name)\n")
            self.connection?.send(content: body, completion: .contentProcessed { _ in })
            DispatchQueue.main.async { self.status = "Sent \(name)" }
        }
    }

    private func safeName(_ raw: String) -> String? {
        var out = ""
        var dotted = false
        for character in raw {
            if character == "/" || character == "\\" || character == ":" { return nil }
            let mapped: Character = character == " " ? "_" : character
            if !(mapped.isLetter || mapped.isNumber || mapped == "." || mapped == "_" || mapped == "-") {
                return nil
            }
            if mapped == "." { dotted = true }
            out.append(mapped)
            if out.count >= 80 { break }
        }
        if out.isEmpty || out.hasPrefix(".") || !dotted { return nil }
        return out
    }
}
