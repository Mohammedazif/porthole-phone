import AVFoundation
import Foundation
import Network
import Photos
import UIKit

final class PullClient: ObservableObject {
    @Published var status = "Opening"
    @Published var address = ""
    @Published var code = ""
    @Published private(set) var linked = false
    @Published private(set) var chosenOriginal = ""
    @Published private(set) var clipStatus = ""
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
    // Accessed only on queue. Explicit selection bypasses visual matching once.
    private var chosenIdentifier: String?
    private var syncReady = false
    private var foreground = true
    private var exporting = false
    private var bodyLeft = 0
    private var bodyKind: Character = "T"
    private var body = Data()
    private var pendingData: Data?
    private var pendingKind: Character = "T"
    private var deferred: (Character, Data)?
    private var seenCount = -1
    private var writingRemote = false
    private var lastSent = ""
    private var launchSend = true
    private var pasteObserver: NSObjectProtocol?

    func chooseOriginal(_ identifier: String) {
        queue.async {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                DispatchQueue.main.async { self.status = "Allow access to that item in Settings → Porthole → Photos" }
                return
            }
            self.chosenIdentifier = identifier
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Selected original"
            DispatchQueue.main.async { self.chosenOriginal = name }
        }
    }

    func clearChosenOriginal() {
        queue.async {
            self.chosenIdentifier = nil
            DispatchQueue.main.async { self.chosenOriginal = "" }
        }
    }

    func bind(index: PhotoIndex) {
        self.index = index
    }

    /// Bonjour is what makes iOS show Local Network. A plain TCP connect often does not.
    func prepare() {
        loadSaved()
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
        // Silence uses a playback session, and iOS then disables Share screen
        // until mirroring takes the sound away. Play it only in the background.
        foreground = true
        stay.stop()
        let board = UIPasteboard.general
        if let waiting = deferred, board.changeCount == seenCount {
            deferred = nil
            applyRemote(kind: waiting.0, data: waiting.1)
        } else {
            deferred = nil
            considerLocal(force: launchSend)
            launchSend = false
        }
        guard !greeted, normalized() != nil else { return }
        connect()
    }

    func enteredBackground() {
        foreground = false
        seenCount = UIPasteboard.general.changeCount
        stay.start()
    }

    /// Reads the iPhone pasteboard from a tap, which iOS allows even when
    /// Paste from Other Apps is still Ask.
    func sendClipboardNow() {
        considerLocal(force: true)
    }

    /// Drops the playback session so the system Share screen button will accept a tap.
    func pauseKeepAlive() {
        stay.stop()
    }

    /// Drops the saved PC so another address and code can be entered.
    func forgetPC() {
        reconnectWork?.cancel()
        connection?.cancel()
        connection = nil
        greeted = false
        syncReady = false
        linked = false
        address = ""
        code = ""
        clipStatus = ""
        UserDefaults.standard.removeObject(forKey: "porthole.host")
        UserDefaults.standard.removeObject(forKey: "porthole.code")
        status = "Enter the address and code shown on the PC."
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
        reconnectWork?.cancel()
        connection?.cancel()
        buffer.removeAll()
        body.removeAll()
        bodyLeft = 0
        syncReady = false
        exporting = false
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
            linked = false
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
                    self.linked = false
                    self.show(hadHello ? "Disconnected. Reconnecting." : "The PC closed the connection. Check the code in F1 help.")
                    self.scheduleReconnect()
                }
                return
            }
            self.receive()
        }
    }

    private func drain() {
        if bodyLeft > 0 {
            let take = min(bodyLeft, buffer.count)
            if take > 0 {
                body.append(buffer.prefix(take))
                buffer.removeFirst(take)
                bodyLeft -= take
            }
            if bodyLeft > 0 { return }
            let payload = body
            let kind = bodyKind
            body.removeAll(keepingCapacity: false)
            applyRemote(kind: kind, data: payload)
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if let header = clipHeader(text) {
                bodyKind = header.0
                bodyLeft = header.1
                body.removeAll(keepingCapacity: false)
                drain()
                return
            }
            handle(text)
        }
    }

    private func handle(_ line: String) {
        if line == "OK" {
            greeted = true
            DispatchQueue.main.async {
                self.linked = true
                self.status = "Connected. You can open Photos."
            }
            return
        }
        if line == "SYNC" {
            guard greeted else { return }
            syncReady = true
            send("SYNC\n")
            startPasteWatch()
            DispatchQueue.main.async {
                self.clipStatus = "Clipboard connected. Paste on the iPhone with Ctrl+V."
                self.sendLaunchClipboardIfNeeded()
            }
            flushClip()
            return
        }
        guard greeted, line.hasPrefix("PULL ") else { return }
        let parts = line.split(separator: " ")
        guard (3...6).contains(parts.count), let hash = UInt64(parts[1], radix: 16),
              let aspect = Double(parts[2]) else {
            send("MISS\n")
            return
        }
        guard let index else {
            send("MISS\n")
            return
        }
        let thumb = parts.count >= 4 ? PictureHash.parseThumb(parts[3]) : nil
        // PCs since phone 2.5 add the same picture at 64 cells a side.
        let detail = parts.count >= 5 ? PictureHash.parseCells(parts[4], side: PictureHash.detailSide) : nil
        // From 2.6: S<aspect>:<32-cell hex>:<64-cell hex> of the whole phone screen.
        var screen: PhotoIndex.Screen?
        if parts.count == 6, parts[5].hasPrefix("S") {
            let fields = parts[5].dropFirst().split(separator: ":")
            if fields.count == 3, let shape = Double(fields[0]), shape > 0,
               let whole = PictureHash.parseThumb(fields[1]),
               let wholeDetail = PictureHash.parseCells(fields[2], side: PictureHash.detailSide) {
                screen = PhotoIndex.Screen(aspect: shape, thumb: whole, detail: wholeDetail)
            }
        }
        if let identifier = chosenIdentifier {
            chosenIdentifier = nil
            DispatchQueue.main.async { self.chosenOriginal = "" }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                send("MISS selected-item-unavailable\n")
                return
            }
            export(asset)
            return
        }
        DispatchQueue.main.async { self.status = "Finding that photo or video" }
        let found = index.match(hash: hash, aspect: aspect, thumb: thumb, detail: detail, screen: screen) { [weak self] text in
            DispatchQueue.main.async { self?.status = text }
        }
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
                    self.status = "Could not identify this item. Use Choose original, then drag again. (\(closest) bits)"
                } else {
                    self.status = "Could not identify this item. Use Choose original, then drag again."
                }
            }
            return
        }
        // The scores go after the name, for the PC log; older PCs ignore them.
        let why = (found.note + " " + found.video).components(separatedBy: .newlines).joined(separator: " ")
        export(asset, note: why.trimmingCharacters(in: .whitespaces))
    }

    private func export(_ asset: PHAsset, note: String = "") {
        exportNote = note
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
        options.progressHandler = { [weak self] progress in
            DispatchQueue.main.async {
                self?.status = "Downloading original from iCloud: \(Int(progress * 100))%"
            }
        }
        let kind = asset.mediaType == .video ? "video" : "photo"
        DispatchQueue.main.async { self.status = "Reading that \(kind)" }
        exporting = true
        PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil {
                    try? FileManager.default.removeItem(at: file)
                    self.exporting = false
                    self.send("MISS\n")
                    self.flushClip()
                    DispatchQueue.main.async { self.status = "Could not read that \(kind)" }
                    return
                }
                self.stream(file, name: name)
            }
        }
    }

    /// FILE line, then the file in 1 MB pieces, each sent after the previous one is taken.
    /// Scores of the match being sent, appended to its FILE line.
    private var exportNote = ""

    private func stream(_ file: URL, name: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, let handle = try? FileHandle(forReadingFrom: file), let link = connection else {
            try? FileManager.default.removeItem(at: file)
            exporting = false
            send("MISS\n")
            flushClip()
            return
        }
        func finish(_ text: String) {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            exporting = false
            flushClip()
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
        send("FILE \(size) \(name)" + (exportNote.isEmpty ? "" : " " + exportNote) + "\n")
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

    private func sendLaunchClipboardIfNeeded() {
        guard launchSend else { return }
        launchSend = false
        considerLocal(force: true)
    }

    private func startPasteWatch() {
        guard pasteObserver == nil else { return }
        pasteObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification, object: UIPasteboard.general, queue: .main
        ) { [weak self] _ in
            guard let self, self.foreground else { return }
            self.considerLocal(force: false)
        }
    }

    private func clipHeader(_ line: String) -> (Character, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "CLIP", let kind = parts[1].first, parts[1].count == 1,
              kind == "T" || kind == "P", let n = Int(parts[2]), n > 0 else { return nil }
        let maxN = kind == "T" ? 256 * 1024 : 8 * 1024 * 1024
        guard n <= maxN else { return nil }
        return (kind, n)
    }

    private func considerLocal(force: Bool) {
        if writingRemote { return }
        let board = UIPasteboard.general
        if !force && board.changeCount == seenCount { return }
        if board.hasImages, let image = board.image, let png = pngData(from: image) {
            let mark = fingerprint(png)
            if !force && mark == lastSent {
                seenCount = board.changeCount
                return
            }
            lastSent = mark
            seenCount = board.changeCount
            queueClip(kind: "P", data: png)
            clipStatus = "Sent the image to the PC"
            return
        }
        if let text = board.string, !text.isEmpty {
            if isPairingText(text) {
                seenCount = board.changeCount
                return
            }
            guard let data = text.data(using: .utf8) else { return }
            if data.count > 256 * 1024 {
                clipStatus = "That copy is too long to send"
                seenCount = board.changeCount
                return
            }
            let mark = fingerprint(data)
            if !force && mark == lastSent {
                seenCount = board.changeCount
                return
            }
            lastSent = mark
            seenCount = board.changeCount
            queueClip(kind: "T", data: data)
            clipStatus = "Sent the copy to the PC"
            return
        }
        seenCount = board.changeCount
        if force {
            clipStatus = "Nothing to send. Settings → Apps → Porthole → Paste from Other Apps → Allow, then copy again."
        }
    }

    private func isPairingText(_ text: String) -> Bool {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var token = ""
        let parts = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count >= 2 {
            raw = parts[0]
            let extra = parts[1].uppercased()
            if extra.count == 8, extra.allSatisfy(\.isHexDigit) { token = extra }
        }
        if let colon = raw.lastIndex(of: ":"), raw.firstIndex(of: ":") == colon {
            let suffix = raw[raw.index(after: colon)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                raw = String(raw[..<colon])
            }
        }
        if token.isEmpty { return false }
        return raw == address && token.uppercased() == code.uppercased()
    }

    private func queueClip(kind: Character, data: Data) {
        queue.async {
            self.pendingKind = kind
            self.pendingData = data
            self.flushClip()
        }
    }

    private func flushClip() {
        guard syncReady, !exporting, let data = pendingData, let link = connection else { return }
        pendingData = nil
        var packet = Data("CLIP \(pendingKind) \(data.count)\n".utf8)
        packet.append(data)
        link.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func applyRemote(kind: Character, data: Data) {
        DispatchQueue.main.async {
            let board = UIPasteboard.general
            self.writingRemote = true
            var wrote = false
            if kind == "T", let text = String(data: data, encoding: .utf8), !text.isEmpty {
                board.string = text
                wrote = true
                self.clipStatus = "PC clipboard is here. Paste with Ctrl+V."
            } else if kind == "P", let image = UIImage(data: data) {
                board.image = image
                wrote = true
                self.clipStatus = "PC image is here. Paste with Ctrl+V."
            }
            if wrote {
                self.seenCount = board.changeCount
                self.lastSent = self.fingerprint(data)
            }
            self.writingRemote = false
            if self.foreground {
                self.deferred = nil
            } else if wrote {
                self.deferred = (kind, data)
            }
        }
    }

    private func pngData(from image: UIImage) -> Data? {
        let maxBytes = 8 * 1024 * 1024
        var scale: CGFloat = 1
        for _ in 0..<8 {
            let current: UIImage
            if scale < 1 {
                let size = CGSize(width: max(1, image.size.width * scale),
                                  height: max(1, image.size.height * scale))
                let renderer = UIGraphicsImageRenderer(size: size)
                current = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            } else {
                current = image
            }
            if let data = current.pngData(), data.count <= maxBytes { return data }
            scale *= 0.7
        }
        return nil
    }

    private func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "\(data.count):\(hash)"
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
    private var wanted = false
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
        guard wanted, !engine.isRunning || !player.isPlaying else { return }
        player.stop()
        start()
    }

    func stop() {
        wanted = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func start() {
        wanted = true
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
