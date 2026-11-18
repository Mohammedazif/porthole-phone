import Foundation
import Network
import Photos

final class PullClient: ObservableObject {
    @Published var status = "Opening"
    @Published var address = ""
    @Published var code = ""
    private let queue = DispatchQueue(label: "porthole.pull")
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var announcer: NWListener?
    private var buffer = Data()
    private var greeted = false
    private weak var index: PhotoIndex?

    func bind(index: PhotoIndex) {
        self.index = index
    }

    /// Bonjour is what makes iOS show Local Network. A plain TCP connect often does not.
    func prepare() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: "_porthole._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.noteBrowse(state) }
        }
        browser.start(queue: queue)
        self.browser = browser
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: "Porthole", type: "_porthole._tcp")
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { self?.noteAnnounce(state) }
            }
            listener.start(queue: queue)
            announcer = listener
        } catch {
            show("Could not ask for Local Network")
        }
        show("Allow Local Network when iOS asks. It is also under Settings → Privacy & Security → Local Network.")
    }

    func cameForward() {
        guard !greeted, normalized() != nil else { return }
        connect()
    }

    func connect() {
        guard let fields = normalized() else {
            show("Enter the address and code from F1 help")
            return
        }
        address = fields.host
        code = fields.token
        connection?.cancel()
        buffer.removeAll()
        greeted = false
        let link = NWConnection(host: NWEndpoint.Host(fields.host), port: 47731, using: .tcp)
        connection = link
        let token = fields.token
        link.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.noteLink(state, token: token)
            }
        }
        link.start(queue: queue)
        show("Connecting to \(fields.host)")
    }

    private func normalized() -> (host: String, token: String)? {
        var raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var token = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count >= 2 {
            raw = parts[0]
            let extra = parts[1].uppercased()
            if token.count != 8, extra.count == 8, extra.allSatisfy(\.isHexDigit) {
                token = extra
            }
        }
        if let colon = raw.lastIndex(of: ":"), raw.firstIndex(of: ":") == colon {
            let suffix = raw[raw.index(after: colon)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                raw = String(raw[..<colon])
            }
        }
        guard !raw.isEmpty, token.count == 8, token.allSatisfy(\.isHexDigit) else { return nil }
        return (raw, token)
    }

    private func noteBrowse(_ state: NWBrowser.State) {
        if case .waiting(let error) = state, isDenied(error) {
            show("Local Network is off. Settings → Privacy & Security → Local Network → turn on Porthole.")
        }
    }

    private func noteAnnounce(_ state: NWListener.State) {
        switch state {
        case .ready:
            if !greeted, connection == nil {
                show("Local Network is on. Enter the F1 address and code, then Connect.")
            }
        case .waiting(let error), .failed(let error):
            if isDenied(error) {
                show("Local Network is off. Settings → Privacy & Security → Local Network → turn on Porthole.")
            }
        default:
            break
        }
    }

    private func noteLink(_ state: NWConnection.State, token: String) {
        switch state {
        case .ready:
            show("Connected")
            send("HELLO \(token)\n")
            receive()
        case .waiting(let error):
            if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied || isDenied(error) {
                show("Local Network is off. Settings → Privacy & Security → Local Network → turn on Porthole.")
            } else {
                show("Waiting for the PC. \(explain(error))")
            }
        case .failed(let error):
            greeted = false
            show("Not connected. \(explain(error))")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func isDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 { return true }
        return false
    }

    private func explain(_ error: NWError) -> String {
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED:
                return "Nothing is answering on port 47731. Start Porthole on the PC."
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN, .ETIMEDOUT:
                return "Use the address from F1 help. The phone and the PC must be on the same Wi-Fi."
            default:
                break
            }
        }
        return String(describing: error)
    }

    private func show(_ text: String) {
        if greeted, text != "Connected. Leave this app open." { return }
        status = text
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
                let hadHello = self.greeted
                self.greeted = false
                DispatchQueue.main.async {
                    self.show(hadHello ? "Disconnected" : "The PC closed the connection. Check the code in F1 help.")
                }
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
        guard let index else {
            send("MISS\n")
            return
        }
        guard index.ready, let asset = index.match(hash: hash, aspect: aspect) else {
            send("MISS\n")
            DispatchQueue.main.async {
                self.status = index.ready ? "No single photo matched the window" : "Load photos, then drag the picture again"
            }
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
