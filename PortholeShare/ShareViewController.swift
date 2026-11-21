import AVFoundation
import ImageIO
import Network
import UIKit
import UniformTypeIdentifiers

/// Share > Porthole from any app: Photos, Files, Voice Memos, Mail. Sends the chosen
/// files themselves to Porthole on the PC, which saves them in the folder set there. Nothing is
/// matched: these are exactly the items picked.
final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let status = UILabel()
    private let bar = UIProgressView(progressViewStyle: .bar)
    private let button = UIButton(type: .custom)
    private let fileStack = UIStackView()
    private let pcName = UILabel()
    private let change = UIButton(type: .system)
    private var sheet: UIStackView?
    private var marks: [UIImageView] = []
    private var readyToSend = false

    /// Everything below is touched only on this queue.
    private let queue = DispatchQueue(label: "porthole.share")
    private var browser: NWBrowser?
    private var finder: NWBrowser?
    private var chosen: NWEndpoint?
    private var connection: NWConnection?
    private var files: [(url: URL, name: String)] = []
    private var folder: URL?
    private var buffer = Data()
    private var stopped = false
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 320)

        titleLabel.text = "Send to this device"
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        let closeButton = UIButton(type: .close)
        closeButton.addTarget(self, action: #selector(ShareViewController.close), for: .touchUpInside)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            var glass = UIButton.Configuration.glass()
            glass.image = UIImage(systemName: "xmark")
            closeButton.configuration = glass
        }
        #endif

        let pc = pcName
        pc.text = "Looking for this device"
        pc.font = .systemFont(ofSize: 17, weight: .semibold)
        var changeConfig = UIButton.Configuration.plain()
        changeConfig.title = "Change"
        changeConfig.contentInsets = .zero
        change.configuration = changeConfig
        change.showsMenuAsPrimaryAction = true
        change.isHidden = true
        status.font = .systemFont(ofSize: 14)
        status.textColor = UIColor(red: 0.09, green: 0.50, blue: 0.24, alpha: 1)
        status.numberOfLines = 2
        status.text = "Looking for this device"
        let pcText = UIStackView(arrangedSubviews: [pc, status])
        pcText.axis = .vertical
        pcText.spacing = 2
        let pcColumn = UIStackView(arrangedSubviews: [pcText, change])
        pcColumn.axis = .horizontal
        pcColumn.alignment = .center
        pcColumn.spacing = 12

        fileStack.axis = .vertical
        fileStack.spacing = 0
        let filesCard = UIView()
        filesCard.backgroundColor = .secondarySystemGroupedBackground
        filesCard.layer.cornerRadius = 16
        filesCard.layer.cornerCurve = .continuous
        filesCard.setContentHuggingPriority(.required, for: .vertical)
        fileStack.translatesAutoresizingMaskIntoConstraints = false
        filesCard.addSubview(fileStack)

        bar.progressTintColor = .label
        bar.trackTintColor = .tertiarySystemFill
        bar.isHidden = true

        button.configuration = ShareViewController.sendStyle(title: "Send")
        button.isEnabled = false
        button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        header.axis = .horizontal
        header.alignment = .center
        let body = UIStackView(arrangedSubviews: [header, pcColumn, filesCard, bar, button])
        body.axis = .vertical
        body.spacing = 14
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setContentHuggingPriority(.required, for: .vertical)
        sheet = body
        view.addSubview(body)
        let bottom = body.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
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

    /// Ink capsule. Glass was drawing a blank pill, so the title is set in both colors.
    private static func sendStyle(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(white: 0.08, alpha: 1) }
        config.baseForegroundColor = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
        config.cornerStyle = .capsule
        config.buttonSize = .large
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 17, weight: .semibold)
            out.foregroundColor = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
            return out
        }
        return config
    }

    /// The Bonjour name is this PC's hostname.
    private func deviceTitle(_ raw: String?) -> String? {
        let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty || name == "Looking for this device" {
            return nil
        }
        return name
    }

    private func showDestination() {
        let device = deviceTitle(pcName.text)
        titleLabel.text = device.map { "Send to \($0)" } ?? "Send to this device"
        if device != nil {
            status.text = "Connected"
            status.textColor = UIColor(red: 0.09, green: 0.50, blue: 0.24, alpha: 1)
        } else {
            status.text = "Looking for this device"
            status.textColor = .secondaryLabel
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let sheet else { return }
        let fitted = sheet.systemLayoutSizeFitting(
            CGSize(width: max(view.bounds.width - 40, 280), height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        let height = fitted + 36
        if abs(preferredContentSize.height - height) > 2 {
            preferredContentSize = CGSize(width: 420, height: min(max(height, 260), 560))
        }
    }

    @objc private func sendTapped() {
        if !readyToSend {
            close()
            return
        }
        readyToSend = false
        button.isEnabled = false
        queue.async {
            if let chosen = self.chosen {
                self.finder?.cancel()
                self.finder = nil
                self.connect(to: chosen)
            } else {
                self.browse()
            }
        }
    }

    /// Lists Porthole PCs while the sheet is open, so it can say which one gets the files.
    private func findPCs() {
        let found = NWBrowser(for: .bonjour(type: "_porthole-share._tcp", domain: nil), using: .tcp)
        found.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.stopped else { return }
            let pcs = results.compactMap { result -> (String, NWEndpoint)? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return (name, result.endpoint)
            }.sorted { $0.0 < $1.0 }
            if self.chosen == nil || !pcs.contains(where: { $0.1 == self.chosen }) {
                self.chosen = pcs.first?.1
            }
            let current = pcs.first(where: { $0.1 == self.chosen })
            DispatchQueue.main.async {
                self.pcName.text = current?.0 ?? "Looking for this device"
                self.showDestination()
                self.change.isHidden = pcs.count < 2
                self.change.menu = UIMenu(children: pcs.map { pc in
                    UIAction(title: pc.0, state: pc.0 == current?.0 ? .on : .off) { [weak self] _ in
                        self?.queue.async {
                            self?.chosen = pc.1
                            DispatchQueue.main.async {
                                self?.pcName.text = pc.0
                                self?.showDestination()
                            }
                        }
                    }
                })
            }
        }
        found.start(queue: queue)
        finder = found
    }

    private func setButton(_ title: String) {
        DispatchQueue.main.async {
            self.button.configuration = ShareViewController.sendStyle(title: title)
            self.button.isEnabled = true
        }
    }

    private func markSent(_ index: Int) {
        DispatchQueue.main.async {
            guard index < self.marks.count else { return }
            UIView.animate(withDuration: 0.25) { self.marks[index].alpha = 1 }
        }
    }

    /// Lists every file and waits for Send. Nothing goes to the PC until that tap.
    private func presentFile() {
        let rows = files.map { file -> (URL, String, Int64) in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return (file.url, file.name, size)
        }
        let total = rows.reduce(Int64(0)) { $0 + $1.2 }
        DispatchQueue.main.async {
            self.fileStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            self.marks = []
            for (index, row) in rows.enumerated() {
                let icon = ShareViewController.fileMark(url: row.0, name: row.1)
                let text = UIStackView()
                text.axis = .vertical
                text.spacing = 1
                let name = UILabel()
                name.text = row.1
                name.font = .systemFont(ofSize: 15, weight: .medium)
                name.lineBreakMode = .byTruncatingMiddle
                name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let bytes = UILabel()
                bytes.text = ByteCountFormatter.string(fromByteCount: row.2, countStyle: .file)
                bytes.font = .systemFont(ofSize: 13)
                bytes.textColor = .secondaryLabel
                text.addArrangedSubview(name)
                text.addArrangedSubview(bytes)
                let mark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
                mark.tintColor = .systemGreen
                mark.alpha = 0
                mark.setContentHuggingPriority(.required, for: .horizontal)
                self.marks.append(mark)
                let line = UIStackView(arrangedSubviews: [icon, text, mark])
                line.axis = .horizontal
                line.spacing = 12
                line.alignment = .center
                line.layoutMargins = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 0)
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
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            self.readyToSend = true
            self.showDestination()
            self.setButton(count == 1 ? "Send · \(size)" : "Send \(count) files · \(size)")
            self.button.isEnabled = true
        }
    }

    /// Photo and video rows show the picture. Everything else shows its type.
    private static func fileMark(url: URL, name: String) -> UIView {
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 36).isActive = true
        box.heightAnchor.constraint(equalToConstant: 44).isActive = true
        box.layer.cornerRadius = 5
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true
        if let image = thumbnail(url: url) {
            let view = UIImageView(image: image)
            view.contentMode = .scaleAspectFill
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: box.topAnchor),
                view.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            ])
            return box
        }
        box.backgroundColor = .systemBackground
        box.layer.borderWidth = 1.0 / UIScreen.main.scale
        box.layer.borderColor = UIColor.separator.cgColor
        let ext = (name as NSString).pathExtension
        let tag = UILabel()
        tag.text = ext.isEmpty ? "FILE" : String(ext.prefix(4)).uppercased()
        tag.font = .systemFont(ofSize: 8, weight: .bold)
        tag.textColor = .white
        tag.backgroundColor = chipColor(ext)
        tag.textAlignment = .center
        tag.layer.cornerRadius = 2
        tag.clipsToBounds = true
        tag.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(tag)
        NSLayoutConstraint.activate([
            tag.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: -2),
            tag.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            tag.heightAnchor.constraint(equalToConstant: 12),
            tag.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        return box
    }

    private static func chipColor(_ ext: String) -> UIColor {
        switch ext.lowercased() {
        case "pdf": return UIColor(red: 0.70, green: 0.14, blue: 0.09, alpha: 1)
        case "zip", "7z", "rar": return UIColor(red: 0.48, green: 0.35, blue: 0.07, alpha: 1)
        case "m4a", "mp3", "wav", "aac": return UIColor(red: 0.36, green: 0.24, blue: 0.54, alpha: 1)
        case "doc", "docx": return UIColor(red: 0.18, green: 0.37, blue: 0.54, alpha: 1)
        default: return UIColor(red: 0.29, green: 0.31, blue: 0.33, alpha: 1)
        }
    }

    private static func thumbnail(url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp"].contains(ext) {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let source, let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: cg)
            }
            return UIImage(contentsOfFile: url.path)
        }
        guard ["mov", "mp4", "m4v"].contains(ext) else { return nil }
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        guard let cg = try? generator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cg)
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
            self.findPCs()
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
            self.status.textColor = .secondaryLabel
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
        finder?.cancel()
        finder = nil
        connection?.cancel()
        connection = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: Reading the items

    /// A photo or video comes in its original format, such as HEIC or MOV: the first type
    /// it offers. Anything else (PDF, ZIP, audio, documents) comes as the file it is.
    /// Web links and bare text are not files and are skipped.
    private static func originalType(of provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        if let media = types.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .image) }) {
            return media
        }
        return types.first { type in
            type.conforms(to: .data) && !type.conforms(to: .url) && type != .plainText && type != .utf8PlainText
        }
    }

    /// Letters, digits, dot, dash and underscore only: what the PC accepts.
    private static func safeName(_ suggested: String?, url: URL, type: UTType, index: Int) -> String {
        var ext = url.pathExtension
        if ext.isEmpty { ext = type.preferredFilenameExtension ?? "dat" }
        var base = suggested ?? url.deletingPathExtension().lastPathComponent
        if (base as NSString).pathExtension.lowercased() == ext.lowercased() {
            base = (base as NSString).deletingPathExtension
        }
        // Photos hands over a temporary copy named with a UUID: name it by kind and time instead.
        if UUID(uuidString: base) != nil {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let kind = type.conforms(to: .movie) ? "Video" : type.conforms(to: .image) ? "Photo" : "File"
            base = "\(kind)-\(stamp.string(from: Date()))" + (index > 0 ? "-\(index + 1)" : "")
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
                self.markSent(index)
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
            let device = self.deviceTitle(self.pcName.text) ?? "this device"
            self.status.textColor = UIColor(red: 0.09, green: 0.50, blue: 0.24, alpha: 1)
            self.status.text = count == 1 ? "Sent to \(device)" : "Sent \(count) files to \(device)"
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
