import AVFoundation
import Foundation
import Network
import Photos
import UIKit

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
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private let stay = SilentKeepAlive()
    private weak var index: PhotoIndex?

    func bind(index: PhotoIndex) {
        self.index = index
    }

    /// Bonjour is what makes iOS show Local Network. A plain TCP connect often does not.
    func prepare() {
        loadSaved()
        stay.start()
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
        if normalized() != nil {
            connect()
        } else {
            show("Allow Local Network when iOS asks. It is also under Settings → Privacy & Security → Local Network.")
        }
    }

    func cameForward() {
        stay.start()
        guard !greeted, normalized() != nil else { return }
        connect()
    }

    func enteredBackground() {
        stay.start()
    }

    func connect() {
        guard let fields = normalized() else {
            show("Enter the address and code from F1 help")
            return
        }
        address = fields.host
        code = fields.token
        UserDefaults.standard.set(fields.host, forKey: "porthole.host")
        UserDefaults.standard.set(fields.token, forKey: "porthole.code")
        stay.start()
        reconnectWork?.cancel()
        connection?.cancel()
        buffer.removeAll()
        greeted = false
        let link = NWConnection(host: NWEndpoint.Host(fields.host), port: 47731, using: .tcp)
        connection = link
        let token = fields.token
        link.stateUpdateHandler = { [weak self, weak link] state in
            DispatchQueue.main.async {
                guard let self, let link, self.connection === link else { return }
                self.noteLink(state, token: token)
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
            reconnectAttempt = 0
            show("Connected")
            send("HELLO \(token)\n")
            receive()
        case .waiting(let error):
            if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied || isDenied(error) {
                show("Local Network is off. Settings → Privacy & Security → Local Network → turn on Porthole.")
            } else {
                // A refused connect (Porthole restarting) waits for a network change that
                // never comes. Drop it and try again on the backoff instead.
                greeted = false
                show("Waiting for the PC. \(explain(error))")
                connection?.cancel()
                scheduleReconnect()
            }
        case .failed(let error):
            greeted = false
            show("Not connected. \(explain(error))")
            scheduleReconnect()
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
        guard let link = connection else { return }
        link.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak link] data, _, complete, error in
            guard let self, let link, self.connection === link else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if error != nil || complete {
                let hadHello = self.greeted
                self.greeted = false
                DispatchQueue.main.async {
                    self.show(hadHello ? "Disconnected. Reconnecting." : "The PC closed the connection. Check the code in F1 help.")
                    self.scheduleReconnect()
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
            DispatchQueue.main.async { self.status = "Connected. You can open Photos." }
            return
        }
        guard greeted, line.hasPrefix("PULL ") else { return }
        let parts = line.split(separator: " ")
        guard parts.count == 3 || parts.count == 4, let hash = UInt64(parts[1], radix: 16),
              let aspect = Double(parts[2]) else {
            send("MISS\n")
            return
        }
        guard let index else {
            send("MISS\n")
            return
        }
        let thumb = parts.count == 4 ? PictureHash.parseThumb(parts[3]) : nil
        let found = index.match(hash: hash, aspect: aspect, thumb: thumb)
        guard index.ready, let asset = found.asset else {
            if found.closest < 65 {
                // The debug thumb stays last: the PC reads the final field as hex.
                let parts = ["MISS \(found.closest)", found.note, found.video,
                             found.debug.trimmingCharacters(in: .whitespaces)]
                send(parts.filter { !$0.isEmpty }.joined(separator: " ") + "\n")
            } else {
                send("MISS\n")
            }
            let closest = found.closest
            DispatchQueue.main.async {
                if !index.ready {
                    self.status = "Load photos, then drag the picture again"
                } else if closest < 65 {
                    self.status = "No single photo matched (closest \(closest) bits)"
                } else {
                    self.status = "No single photo matched the window"
                }
            }
            return
        }
        export(asset)
    }

    private func export(_ asset: PHAsset) {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = asset.mediaType == .video
            ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        guard let resource = wanted.lazy.compactMap({ type in resources.first(where: { $0.type == type }) }).first else {
            send("MISS\n")
            return
        }
        guard let name = safeName(resource.originalFilename) else {
            send("MISS\n")
            return
        }
        // Written to a file first: the PC needs the size before the bytes, and a video
        // can be far larger than what fits in memory.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let kind = asset.mediaType == .video ? "video" : "photo"
        DispatchQueue.main.async { self.status = "Reading that \(kind)" }
        PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? FileManager.default.removeItem(at: file)
                self.send("MISS\n")
                DispatchQueue.main.async { self.status = "Could not read that \(kind)" }
                return
            }
            self.stream(file, name: name)
        }
    }

    /// FILE line, then the file in 1 MB pieces, each sent after the previous one is taken.
    private func stream(_ file: URL, name: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, let handle = try? FileHandle(forReadingFrom: file), let link = connection else {
            try? FileManager.default.removeItem(at: file)
            send("MISS\n")
            return
        }
        func finish(_ text: String) {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async { self.status = text }
        }
        func next() {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty {
                finish("Sent \(name)")
                return
            }
            link.send(content: chunk, completion: .contentProcessed { error in
                if error != nil {
                    finish("Sending \(name) stopped")
                    return
                }
                next()
            })
        }
        send("FILE \(size) \(name)\n")
        next()
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

    private func loadSaved() {
        let defaults = UserDefaults.standard
        if address.isEmpty, let host = defaults.string(forKey: "porthole.host") {
            address = host
        }
        if code.isEmpty, let token = defaults.string(forKey: "porthole.code") {
            code = token
        }
        guard normalized() == nil, let pasted = UIPasteboard.general.string else { return }
        let savedAddress = address
        let savedCode = code
        address = pasted
        code = ""
        if normalized() == nil {
            address = savedAddress
            code = savedCode
        }
    }

    private func scheduleReconnect() {
        guard normalized() != nil else { return }
        reconnectWork?.cancel()
        let delay = min(2 << min(reconnectAttempt, 3), 15)
        reconnectAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.greeted else { return }
            self.connect()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
    }
}

/// Silent playback so iOS keeps this process alive after the user opens Photos.
private final class SilentKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var observers: [NSObjectProtocol] = []

    /// iOS stops the engine when the audio route changes, for example when AirPlay
    /// mirroring starts or Porthole on the PC restarts. Without the silence playing,
    /// the app is suspended a few seconds later and the photo link drops.
    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in self?.restart() })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.restart() })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restart()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func restart() {
        if !engine.isRunning || !player.isPlaying {
            player.stop()
            start()
        }
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1) else { return }
            if !attached {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                attached = true
            }
            engine.mainMixerNode.outputVolume = 0
            if !engine.isRunning {
                try engine.start()
            }
            guard !player.isPlaying else { return }
            let frames: AVAudioFrameCount = 8000
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        } catch {
            return
        }
    }
}
