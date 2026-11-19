import Network
import UIKit
import UniformTypeIdentifiers

/// Photos > Select > Share > Porthole. Sends the chosen photos and videos themselves to
/// Porthole on the PC, which then carries them all on the next Ctrl+drag out of its
/// window. Nothing is matched: these are exactly the items picked.
final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let status = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let button = UIButton(type: .system)

    /// Everything below is touched only on this queue.
    private let queue = DispatchQueue(label: "porthole.share")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var files: [(url: URL, name: String)] = []
    private var folder: URL?
    private var buffer = Data()
    private var stopped = false
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        titleLabel.text = "Send to Porthole"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        status.text = "Getting the originals ready"
        status.numberOfLines = 0
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .body)
        button.setTitle("Cancel", for: .normal)
        button.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleLabel, status, bar, button])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.collect(providers)
        }
    }

    @objc private func close() {
        queue.async { self.stop() }
        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func say(_ text: String, progress: Float? = nil) {
        DispatchQueue.main.async {
            self.status.text = text
            if let progress { self.bar.setProgress(progress, animated: true) }
        }
    }

    /// Shows why, and leaves the sheet open until Close.
    private func fail(_ text: String) {
        guard !stopped else { return }
        stop()
        say(text)
        DispatchQueue.main.async { self.button.setTitle("Close", for: .normal) }
    }

    private func stop() {
        stopped = true
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: Reading the items

    /// The first type each item offers is its original format, such as HEIC or MOV.
    private static func originalType(of provider: NSItemProvider) -> UTType? {
        for id in provider.registeredTypeIdentifiers {
            guard let type = UTType(id) else { continue }
            if type.conforms(to: .movie) || type.conforms(to: .image) { return type }
        }
        return nil
    }

    /// Letters, digits, dot, dash and underscore only: what the PC accepts.
    private static func safeName(_ suggested: String?, url: URL, type: UTType, index: Int) -> String {
        var ext = url.pathExtension
        if ext.isEmpty { ext = type.preferredFilenameExtension ?? "dat" }
        var base = suggested ?? url.deletingPathExtension().lastPathComponent
        if (base as NSString).pathExtension.lowercased() == ext.lowercased() {
            base = (base as NSString).deletingPathExtension
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        func clean(_ text: String) -> String { String(text.map { allowed.contains($0) ? $0 : "_" }) }
        let cleanExt = String(clean(ext).prefix(8))
        var name = clean(base).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name.isEmpty { name = "item\(index + 1)" }
        return String(name.prefix(70 - cleanExt.count)) + "." + cleanExt
    }

    private func collect(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { fail("Nothing to send."); return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        folder = temp
        let lock = NSLock()
        var collected: [(index: Int, url: URL, name: String)] = []
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            guard let type = Self.originalType(of: provider) else { continue }
            group.enter()
            // The system deletes this copy when the handler returns, so keep our own.
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
                defer { group.leave() }
                guard let url else { return }
                let name = ShareViewController.safeName(provider.suggestedName, url: url, type: type, index: index)
                let target = temp.appendingPathComponent("\(index)-\(name)")
                guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
                lock.lock()
                collected.append((index, target, name))
                let count = collected.count
                lock.unlock()
                self?.say("Getting the originals ready \(count) of \(providers.count)")
            }
        }
        group.notify(queue: queue) {
            guard !self.stopped else { return }
            self.files = collected.sorted { $0.index < $1.index }.map { ($0.url, $0.name) }
            if self.files.isEmpty {
                self.fail("These items could not be read.")
                return
            }
            self.say("Looking for Porthole on the PC")
            self.browse()
        }
    }

    // MARK: Sending

    private func browse() {
        let found = NWBrowser(for: .bonjour(type: "_porthole-share._tcp", domain: nil), using: .tcp)
        found.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, !self.stopped, let first = results.first else { return }
            self.connect(to: first.endpoint)
        }
        found.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.fail("Allow Local Network for Porthole in Settings, then share again.") }
        }
        found.start(queue: queue)
        browser = found
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.connection == nil, !self.stopped else { return }
            self.fail("Porthole was not found on this Wi-Fi. Open Porthole on the PC, then share again.")
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        browser?.cancel()
        browser = nil
        let parameters = NWParameters.tcp
        // Porthole listens on IPv4, and only takes files from the phone whose photo link it knows.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let link = NWConnection(to: endpoint, using: parameters)
        link.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                link.send(content: Data("PSHR 1 \(self.files.count)\n".utf8), completion: .contentProcessed { _ in })
                self.sendFile(0)
            case .failed:
                self.fail("Lost the connection to the PC. Try again.")
            default:
                break
            }
        }
        connection = link
        link.start(queue: queue)
    }

    private func sendFile(_ index: Int) {
        guard let link = connection, !stopped else { return }
        if index == files.count {
            link.send(content: Data("DONE\n".utf8), completion: .contentProcessed { _ in })
            readLine { [weak self] _ in self?.sent() }
            return
        }
        let file = files[index]
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value,
              size > 0, let handle = try? FileHandle(forReadingFrom: file.url) else {
            fail("Could not read \(file.name).")
            return
        }
        say("Sending \(index + 1) of \(files.count)", progress: Float(index) / Float(files.count))
        link.send(content: Data("FILE \(size) \(file.name)\n".utf8), completion: .contentProcessed { _ in })
        pump(handle, left: size, index: index)
    }

    /// One megabyte at a time, each after the last has gone, so a long video never sits
    /// in this extension's small memory.
    private func pump(_ handle: FileHandle, left: Int64, index: Int) {
        guard let link = connection, !stopped else {
            try? handle.close()
            return
        }
        if left <= 0 {
            try? handle.close()
            readLine { [weak self] line in
                guard let self else { return }
                guard line == "OK" else {
                    self.fail(index == 0
                        ? "Porthole on the PC did not accept this iPhone. Open the Porthole app on this iPhone so the PC knows it, then share again."
                        : "The PC stopped after \(index) of \(self.files.count).")
                    return
                }
                self.sendFile(index + 1)
            }
            return
        }
        let chunk = autoreleasepool { handle.readData(ofLength: Int(min(left, 1 << 20))) }
        if chunk.isEmpty {
            try? handle.close()
            fail("Could not read \(files[index].name).")
            return
        }
        link.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                self.fail("Lost the connection to the PC while sending.")
                return
            }
            self.pump(handle, left: left - Int64(chunk.count), index: index)
        })
    }

    private func readLine(_ done: @escaping (String?) -> Void) {
        if let newline = buffer.firstIndex(of: 10) {
            let line = String(data: buffer[buffer.startIndex..<newline], encoding: .utf8)
            buffer.removeSubrange(buffer.startIndex...newline)
            done(line?.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        guard let link = connection else { done(nil); return }
        link.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.readLine(done)
            } else if complete || error != nil {
                done(nil)
            } else {
                self.readLine(done)
            }
        }
    }

    private func sent() {
        let count = files.count
        stop()
        say("Sent \(count) item\(count == 1 ? "" : "s"). On the PC, hold Ctrl and drag out of the Porthole window.",
            progress: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
