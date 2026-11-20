import Network
import UIKit
import UniformTypeIdentifiers

/// Photos > Select > Share > Porthole. Sends the chosen photos and videos themselves to
/// Porthole on the PC, which saves them in Downloads. Nothing is matched: these are
/// exactly the items picked.
final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let bar = UIProgressView(progressViewStyle: .bar)
    private let button = UIButton(type: .custom)
    private let fileStack = UIStackView()
    private let sizeLabel = UILabel()
    private var readyToSend = false

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
        view.backgroundColor = .systemGroupedBackground
        preferredContentSize = CGSize(width: 420, height: 560)

        let title = UILabel()
        title.text = "Send to PC"
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let close = UIButton(type: .close)
        close.addTarget(self, action: #selector(close), for: .touchUpInside)

        let pc = UILabel()
        pc.text = "Porthole"
        pc.font = .systemFont(ofSize: 17, weight: .semibold)
        status.font = .systemFont(ofSize: 14)
        status.textColor = .secondaryLabel
        status.numberOfLines = 2
        status.text = "Getting the originals ready"
        let pcColumn = UIStackView(arrangedSubviews: [pc, status])
        pcColumn.axis = .vertical
        pcColumn.spacing = 2

        let destTitle = UILabel()
        destTitle.text = "Save on PC to"
        destTitle.font = .systemFont(ofSize: 15)
        destTitle.textColor = .secondaryLabel
        let dest = UILabel()
        dest.text = "Downloads"
        dest.font = .systemFont(ofSize: 15, weight: .semibold)
        let destRow = UIStackView(arrangedSubviews: [destTitle, dest])
        destRow.axis = .horizontal
        destRow.distribution = .equalSpacing

        fileStack.axis = .vertical
        fileStack.spacing = 0
        let filesCard = UIView()
        filesCard.backgroundColor = .secondarySystemGroupedBackground
        filesCard.layer.cornerRadius = 16
        filesCard.layer.cornerCurve = .continuous
        fileStack.translatesAutoresizingMaskIntoConstraints = false
        filesCard.addSubview(fileStack)

        bar.progressTintColor = .label
        bar.trackTintColor = .tertiarySystemFill
        bar.isHidden = true

        var config = UIButton.Configuration.filled()
        config.title = "Send"
        config.baseBackgroundColor = .label
        config.baseForegroundColor = .systemBackground
        config.cornerStyle = .capsule
        config.buttonSize = .large
        button.configuration = config
        button.isEnabled = false
        button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [title, close])
        header.axis = .horizontal
        header.alignment = .center
        let body = UIStackView(arrangedSubviews: [header, pcColumn, destRow, filesCard, sizeLabel, bar, button])
        body.axis = .vertical
        body.spacing = 16
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        sizeLabel.font = .systemFont(ofSize: 13)
        sizeLabel.textColor = .secondaryLabel
        let bottom = body.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            bottom,
            fileStack.topAnchor.constraint(equalTo: filesCard.topAnchor, constant: 4),
            fileStack.leadingAnchor.constraint(equalTo: filesCard.leadingAnchor, constant: 12),
            fileStack.trailingAnchor.constraint(equalTo: filesCard.trailingAnchor, constant: -12),
            fileStack.bottomAnchor.constraint(equalTo: filesCard.bottomAnchor, constant: -4),
            button.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    @objc private func sendTapped() {
        if !readyToSend {
            close()
            return
        }
        readyToSend = false
        button.isEnabled = false
        queue.async { self.browse() }
    }

    private func setButton(_ title: String) {
        DispatchQueue.main.async {
            guard var config = self.button.configuration else { return }
            config.title = title
            self.button.configuration = config
            self.button.isEnabled = true
        }
    }

    /// Lists every file and waits for Send. Nothing goes to the PC until that tap.
    private func presentFile() {
        let rows = files.map { file -> (String, Int64) in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return (file.name, size)
        }
        let total = rows.reduce(Int64(0)) { $0 + $1.1 }
        DispatchQueue.main.async {
            self.fileStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (index, row) in rows.enumerated() {
                let name = UILabel()
                name.text = row.0
                name.font = .systemFont(ofSize: 15, weight: .medium)
                name.lineBreakMode = .byTruncatingMiddle
                let bytes = UILabel()
                bytes.text = ByteCountFormatter.string(fromByteCount: row.1, countStyle: .file)
                bytes.font = .systemFont(ofSize: 13)
                bytes.textColor = .secondaryLabel
                bytes.setContentHuggingPriority(.required, for: .horizontal)
                let line = UIStackView(arrangedSubviews: [name, bytes])
                line.axis = .horizontal
                line.spacing = 8
                line.layoutMargins = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
                line.isLayoutMarginsRelativeArrangement = true
                if index < rows.count - 1 {
                    let wrap = UIStackView(arrangedSubviews: [line])
                    wrap.axis = .vertical
                    let rule = UIView()
                    rule.backgroundColor = .separator
                    rule.translatesAutoresizingMaskIntoConstraints = false
                    rule.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
                    wrap.addArrangedSubview(rule)
                    self.fileStack.addArrangedSubview(wrap)
                } else {
                    self.fileStack.addArrangedSubview(line)
                }
            }
            let count = rows.count
            self.sizeLabel.text = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            self.status.text = "Connected · Downloads"
            self.setButton(count == 1 ? "Send 1 file" : "Send \(count) files")
            self.readyToSend = true
            self.button.isEnabled = true
        }
    }

    private func pulse(_ on: Bool) {
        _ = on
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
            if let progress {
                self.bar.isHidden = false
                self.bar.setProgress(progress, animated: true)
            }
        }
    }

    /// Shows why, and leaves the sheet open until Close.
    private func fail(_ text: String) {
        guard !stopped else { return }
        stop()
        say(text)
        pulse(false)
        DispatchQueue.main.async { self.readyToSend = false }
        setButton("Close")
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
            self.presentFile()
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
                self.pulse(true)
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
        let count = Float(max(files.count, 1))
        say("Sending \(index + 1) of \(files.count)", progress: Float(index) / count)
        link.send(content: Data("FILE \(size) \(file.name)\n".utf8), completion: .contentProcessed { _ in })
        pump(handle, left: size, total: size, index: index)
    }

    /// One megabyte at a time, each after the last has gone, so a long video never sits
    /// in this extension's small memory.
    private func pump(_ handle: FileHandle, left: Int64, total: Int64, index: Int) {
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
        let count = Float(max(files.count, 1))
        let sentInFile = Float(total - left) / Float(max(total, 1))
        say("Sending \(index + 1) of \(files.count)", progress: min(0.98, (Float(index) + sentInFile) / count))
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
            self.pump(handle, left: left - Int64(chunk.count), total: total, index: index)
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
        DispatchQueue.main.async {
            self.status.text = count == 1 ? "Sent to Porthole" : "Sent \(count) files to Porthole"
            self.bar.isHidden = false
            self.bar.setProgress(1, animated: true)
            self.readyToSend = false
            self.setButton("Sent")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
