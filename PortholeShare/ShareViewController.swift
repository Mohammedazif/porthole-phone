import Network
import UIKit
import UniformTypeIdentifiers

/// A document page with its file type on a colored tag, as in the design.
private final class FileTile: UIView {
    private let badge = UILabel()

    init(fileExtension: String) {
        super.init(frame: .zero)
        let kind = fileExtension.uppercased()
        backgroundColor = .white
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        isAccessibilityElement = false
        badge.text = String(kind.prefix(4))
        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = Self.color(for: kind)
        badge.layer.cornerRadius = 3
        badge.layer.masksToBounds = true
        badge.isHidden = kind.isEmpty
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 40),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -3),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            badge.heightAnchor.constraint(equalToConstant: 13),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        updateBorder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (tile: FileTile, _: UITraitCollection) in
            tile.updateBorder()
        }
    }

    required init?(coder: NSCoder) { nil }

    private func updateBorder() {
        layer.borderColor = (traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)
            : UIColor(red: 0xD5 / 255, green: 0xD8 / 255, blue: 0xDD / 255, alpha: 1)).cgColor
    }

    private static func color(for kind: String) -> UIColor {
        func rgb(_ value: Int) -> UIColor {
            UIColor(red: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
                    blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
        switch kind {
        case "PDF": return rgb(0xB42318)
        case "ZIP", "RAR", "7Z", "TAR", "GZ": return rgb(0x7A5A12)
        case "M4A", "MP3", "WAV", "AAC", "FLAC": return rgb(0x5B3E8A)
        case "HEIC", "JPG", "JPEG", "PNG", "GIF", "MOV", "MP4", "WEBP": return rgb(0x2F5F8A)
        default: return rgb(0x4A4E55)
        }
    }
}

/// Sends the files chosen in the system share sheet to the reviewed, paired PC.
final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let destinationLabel = UILabel()
    private let status = UILabel()
    private let statusDot = UIView()
    private let bar = UIProgressView(progressViewStyle: .bar)
    private let button = UIButton(type: .system)
    private let fileStack = UIStackView()
    private var marks: [UIImageView] = []
    private var transfer: ShareTransfer?
    private var readyToSend = false
    private var finished = false
    private var closing = false
    private var started = false

    private static func card() -> UIStackView {
        let card = UIStackView()
        card.axis = .vertical
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        return card
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        preferredContentSize = CGSize(width: 420, height: 600)
        titleLabel.text = "Send to PC"
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits.insert(.header)

        let closeButton = UIButton(type: .close)
        closeButton.accessibilityLabel = "Close Porthole"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            var glass = UIButton.Configuration.glass()
            glass.image = UIImage(systemName: "xmark")
            closeButton.configuration = glass
        }
        #endif
        let balance = UIView()
        let header = UIStackView(arrangedSubviews: [closeButton, titleLabel, balance])
        header.alignment = .center
        header.spacing = 8
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            balance.widthAnchor.constraint(equalToConstant: 44),
        ])

        // Files, one row each.
        fileStack.axis = .vertical
        let files = Self.card()
        files.addArrangedSubview(fileStack)

        // The paired PC and what is happening with it.
        let icon = UIImageView(image: UIImage(systemName: "desktopcomputer",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)
            : UIColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1) }
        icon.layer.cornerRadius = 9
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.isAccessibilityElement = false
        destinationLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        destinationLabel.adjustsFontForContentSizeCategory = true
        destinationLabel.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        statusDot.backgroundColor = .systemGreen
        statusDot.layer.cornerRadius = 3.5
        statusDot.isHidden = true
        let statusLine = UIStackView(arrangedSubviews: [statusDot, status])
        statusLine.alignment = .center
        statusLine.spacing = 6
        let names = UIStackView(arrangedSubviews: [destinationLabel, statusLine])
        names.axis = .vertical
        names.spacing = 2
        let pcRow = UIStackView(arrangedSubviews: [icon, names])
        pcRow.alignment = .center
        pcRow.spacing = 12
        pcRow.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        pcRow.isLayoutMarginsRelativeArrangement = true
        let destination = Self.card()
        destination.addArrangedSubview(pcRow)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            pcRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
        ])

        let details = UIStackView(arrangedSubviews: [files, destination])
        details.axis = .vertical
        details.spacing = 16
        details.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.addSubview(details)

        bar.progressTintColor = .label
        bar.trackTintColor = .tertiarySystemFill
        bar.accessibilityLabel = "Transfer progress"
        bar.isHidden = true
        configureButton("Send", enabled: false)
        button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        let body = UIStackView(arrangedSubviews: [header, scroll, bar, button])
        body.axis = .vertical
        body.spacing = 16
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
            body.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            details.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            details.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            details.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            details.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        guard TrustedPeerStore.available else {
            status.text = "This install did not grant Share access to the Porthole App Group."
            finished = true
            configureButton("Done", enabled: true)
            return
        }
        guard let peer = TrustedPeerStore.load() else {
            status.text = "Pair a PC in Porthole first."
            finished = true
            configureButton("Done", enabled: true)
            return
        }
        destinationLabel.text = peer.name
        guard TrustedPeerStore.fileSharePeer(matching: peer) != nil else {
            status.text = "Open Porthole once to finish setting up Share for this PC."
            finished = true
            configureButton("Done", enabled: true)
            return
        }
        status.text = "Preparing selected files for this PC…"
        let transfer = ShareTransfer(peer: peer, onFiles: { [weak self] in self?.presentFiles($0) },
                                     onStatus: { [weak self] in self?.updateStatus($0, progress: $1, announce: $2) },
                                     onSaved: { [weak self] index in
                                         guard let self, !self.closing, self.marks.indices.contains(index) else { return }
                                         self.marks[index].isHidden = false
                                     }, onAction: { [weak self] title, retry in
                                         guard let self, !self.closing else { return }
                                         self.readyToSend = retry
                                         self.finished = !retry
                                         self.statusDot.isHidden = title != "Done"
                                         self.configureButton(title, enabled: true)
                                     })
        self.transfer = transfer
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        transfer.prepare(providers)
    }

    private func configureButton(_ title: String, enabled: Bool) {
        // The prominent system glass style is available on iOS 26. A filled
        // capsule provides the same hierarchy on the deployment target.
        var configuration = UIButton.Configuration.filled()
        #if compiler(>=6.2)
        if #available(iOS 26, *) { configuration = .prominentGlass() }
        #endif
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        configuration.title = title
        configuration.baseBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(white: 0.08, alpha: 1) }
        configuration.baseForegroundColor = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
        configuration.titleTextAttributesTransformer = .init { attributes in
            var output = attributes
            output.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            return output
        }
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.isEnabled = enabled
    }

    @objc private func sendTapped() {
        if finished { close(); return }
        guard readyToSend else { return }
        readyToSend = false
        button.isEnabled = false
        transfer?.send()
    }

    @objc private func close() {
        guard !closing else { return }
        closing = true
        transfer?.cancel()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func presentFiles(_ items: [ShareTransfer.Item]) {
        guard !closing else { return }
        for (index, item) in items.enumerated() {
            let tile = FileTile(fileExtension: (item.name as NSString).pathExtension)
            let name = UILabel()
            name.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .medium))
            name.adjustsFontForContentSizeCategory = true
            name.lineBreakMode = .byTruncatingMiddle
            name.text = item.name
            let size = UILabel()
            size.font = .preferredFont(forTextStyle: .footnote)
            size.adjustsFontForContentSizeCategory = true
            size.textColor = .secondaryLabel
            size.text = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            let labels = UIStackView(arrangedSubviews: [name, size])
            labels.axis = .vertical
            labels.spacing = 1
            let mark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            mark.tintColor = .systemGreen
            mark.isHidden = true
            mark.isAccessibilityElement = true
            mark.accessibilityLabel = "Saved on PC"
            marks.append(mark)
            let row = UIStackView(arrangedSubviews: [tile, labels, mark])
            row.alignment = .center
            row.spacing = 12
            row.layoutMargins = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
            row.isLayoutMarginsRelativeArrangement = true
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
            mark.setContentHuggingPriority(.required, for: .horizontal)
            labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fileStack.addArrangedSubview(row)
            if index < items.count - 1 {
                let rule = UIView()
                rule.backgroundColor = .separator
                rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                let inset = UIStackView(arrangedSubviews: [rule])
                inset.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)
                inset.isLayoutMarginsRelativeArrangement = true
                fileStack.addArrangedSubview(inset)
            }
        }
        status.text = "Paired PC"
        readyToSend = true
        let total = ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.bytes }, countStyle: .file)
        configureButton(items.count == 1 ? "Send 1 file · \(total)" : "Send \(items.count) files · \(total)",
                        enabled: true)
    }

    private func updateStatus(_ text: String, progress: Double?, announce: Bool) {
        guard !closing else { return }
        status.text = text
        if let progress {
            bar.isHidden = false
            bar.setProgress(Float(progress), animated: true)
            bar.accessibilityValue = "\(Int(progress * 100)) percent"
        }
        if announce { UIAccessibility.post(notification: .announcement, argument: text) }
    }
}

/// Serial ownership keeps file-provider and socket work independent of UIKit's main actor.
private final class ShareTransfer {
    struct Item {
        let url: URL
        let name: String
        let bytes: Int64
        let digest: String
        var id = UUID()
        var generatedName = false
        var ticket: String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    }

    private let peer: TrustedPeer
    private let onFiles: @MainActor ([Item]) -> Void
    private let onStatus: @MainActor (String, Double?, Bool) -> Void
    private let onSaved: @MainActor (Int) -> Void
    private let onAction: @MainActor (String, Bool) -> Void
    private let queue = DispatchQueue(label: "porthole.share")
    private let preparation = Preparation()
    private var connection: NWConnection?
    private var savedPCSearch: SavedPCConnection?
    private var deadline: DispatchWorkItem?
    private var activeHandle: FileHandle?
    private var files: [Item] = []
    private var acknowledged = Set<Int>()
    private var batch: [Int] = []
    private var journalBatch: OutboundTransferJournal.Batch?
    private var manifest: OutboundTransferManifest?
    private var buffer = Data()
    private var stopped = false
    private var awaitingReceipt = false
    private var protocolVersion: Int?
    private var lastProgressAt = DispatchTime.now()

    init(peer: TrustedPeer, onFiles: @escaping @MainActor ([Item]) -> Void,
         onStatus: @escaping @MainActor (String, Double?, Bool) -> Void,
         onSaved: @escaping @MainActor (Int) -> Void, onAction: @escaping @MainActor (String, Bool) -> Void) {
        self.peer = peer
        self.onFiles = onFiles
        self.onStatus = onStatus
        self.onSaved = onSaved
        self.onAction = onAction
    }

    func prepare(_ providers: [NSItemProvider]) {
        queue.async { self.collect(providers) }
    }

    func send() {
        queue.async {
            guard !self.stopped, self.connection == nil, self.savedPCSearch == nil else { return }
            guard !self.files.contains(where: { $0.bytes > TransferStaging.desktopFileBytes }) else {
                self.fail(TransferStaging.Failure.desktopFileLimit.localizedDescription, retry: false)
                return
            }
            guard let current = TrustedPeerStore.load() else {
                self.fail("Reconnect to the reviewed PC in Porthole and retry.")
                return
            }
            guard current.samePairing(as: self.peer) else {
                self.fail("The paired PC changed. Close Share and review the new destination.", retry: false)
                return
            }
            guard let destination = TrustedPeerStore.fileSharePeer(matching: current) else {
                self.fail("Open Porthole to finish setting up Share for this PC.")
                return
            }
            let version = self.protocolVersion ?? destination.receiveVersion
            guard destination.receiveVersion >= version else {
                self.fail("Update Porthole on the PC to resume this transfer.")
                return
            }
            guard let batch = self.journalBatch, var manifest = self.manifest else {
                self.fail("Porthole could not locate the prepared files.", retry: false)
                return
            }
            manifest.version = version
            do { try batch.save(manifest) }
            catch { self.fail("Unable to save the transfer state on this iPhone."); return }
            self.manifest = manifest
            self.protocolVersion = version
            self.connect(to: destination, version: version)
        }
    }

    func cancel() {
        preparation.cancel()
        queue.async { self.stop() }
    }

    private func updateStatus(_ text: String, progress: Double? = nil, announce: Bool = false) {
        DispatchQueue.main.async { self.onStatus(text, progress, announce) }
    }

    private func collect(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty, providers.count <= TransferStaging.maxItems else {
            fail("Choose between 1 and 500 files to share.", retry: false); return
        }
        guard let journal = OutboundTransferJournal.shared() else {
            fail("Porthole could not open its shared file transfer storage.", retry: false); return
        }
        do {
            let batch = try journal.makeBatch(for: peer)
            journalBatch = batch
            collect(providers, at: 0, in: batch.folder, remaining: TransferStaging.maxBatchBytes)
        } catch {
            fail("Unable to prepare file storage: \(error.localizedDescription)", retry: false)
        }
    }

    private func collect(_ providers: [NSItemProvider], at index: Int, in directory: URL, remaining: Int64) {
        guard !stopped, !preparation.cancelled else { return }
        guard let batch = journalBatch else {
            fail("Porthole could not keep the prepared files.", retry: false); return
        }
        guard index < providers.count else {
            let manifest = OutboundTransferManifest(id: batch.id, destination: peer.remembered,
                                                    files: files.map { item in
                .init(id: item.id, name: item.name, bytes: item.bytes, digest: item.digest,
                      sent: false, generatedName: item.generatedName)
            })
            do {
                let reviewed = try batch.saveSelection(manifest, version: peer.receiveVersion)
                files = reviewed.files.enumerated().map { index, file in
                    Item(url: batch.itemURL(named: file.name, index: index), name: file.name,
                         bytes: file.bytes, digest: file.digest, id: file.id, generatedName: file.generatedName == true)
                }
                self.manifest = reviewed
                protocolVersion = reviewed.version
            }
            catch { fail("Porthole could not save the transfer for retry.", retry: false); return }
            let staged = files
            DispatchQueue.main.async { self.onFiles(staged) }
            return
        }
        let provider = providers[index]
        guard let type = Self.originalType(of: provider) else {
            fail("Selected item \(index + 1) is not a shareable file. Choose files and try again.", retry: false); return
        }
        let itemDirectory = directory.appendingPathComponent(String(index), isDirectory: true)
        do { try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true) }
        catch { fail(error.localizedDescription, retry: false); return }
        let token = preparation.beginItem()
        updateStatus("Preparing file \(index + 1) of \(providers.count)…")
        // Copy inside the provider callback. Its temporary item expires when the callback returns.
        let progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, providerError in
            guard let self, !self.preparation.isCancelled(token) else { return }
            let result = Result<Item, Error> {
                guard let url else { throw providerError ?? CocoaError(.fileReadNoSuchFile) }
                let (name, generated) = Self.wireName(provider.suggestedName, url: url, type: type, index: index)
                let target = itemDirectory.appendingPathComponent(name)
                let snapshot = try TransferStaging.snapshot(url, to: target, remaining: remaining, reserve: batch.reserve) {
                    self.preparation.isCancelled(token) || batch.isRevoked
                }
                return Item(url: target, name: name, bytes: snapshot.bytes, digest: snapshot.digest,
                            generatedName: generated)
            }
            self.queue.async {
                guard !self.stopped, !self.preparation.isCancelled(token) else { return }
                self.preparation.finishItem(token)
                switch result {
                case .success(let item):
                    self.files.append(item)
                    self.collect(providers, at: index + 1, in: directory, remaining: remaining - item.bytes)
                case .failure(let error):
                    self.fail("Could not prepare item \(index + 1). \(error.localizedDescription)", retry: false)
                }
            }
        }
        preparation.install(progress, for: token)
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, !self.stopped, !self.preparation.isCancelled(token) else { return }
            self.fail("A selected file took too long to prepare. Open the file in its app and try sharing again.", retry: false)
        }
    }

    private static func originalType(of provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        return types.first { $0.conforms(to: .movie) || $0.conforms(to: .image) }
            ?? types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
    }

    private static func wireName(_ suggested: String?, url: URL, type: UTType, index: Int) -> (String, Bool) {
        let ext = url.pathExtension.isEmpty ? type.preferredFilenameExtension ?? "dat" : url.pathExtension
        var base = suggested ?? url.deletingPathExtension().lastPathComponent
        if (base as NSString).pathExtension.lowercased() == ext.lowercased() {
            base = (base as NSString).deletingPathExtension
        }
        let generated = UUID(uuidString: base) != nil
        if generated {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            base = "File-\(stamp.string(from: Date()))-\(index + 1)"
        }
        return (TransferFileName.make("\(base).\(ext)", index: index), generated)
    }

    private func connect(to peer: TrustedPeer, version: Int) {
        batch = files.indices.filter { !acknowledged.contains($0) }
        if batch.isEmpty { sent(sessionClosed: true); return }
        let search = SavedPCConnection(peer: peer, port: 47733, queue: queue)
        savedPCSearch = search
        updateStatus("Finding \(peer.name) on Wi-Fi…", progress: Double(acknowledged.count) / Double(files.count))
        search.start { [weak self] result in
            guard let self, !self.stopped else { return }
            self.savedPCSearch = nil
            switch result {
            case .success(let destination):
                self.sendBatch(to: destination.peer, on: destination.link, version: version)
            case .failure(.localNetworkDenied):
                self.fail("Allow Porthole in Settings › Privacy & Security › Local Network.")
            case .failure(.unavailable):
                self.fail("Could not reach \(peer.name). Keep Porthole running on the PC and connect both devices to the same Wi-Fi network.")
            }
        }
    }

    private func sendBatch(to peer: TrustedPeer, on link: NWConnection, version: Int) {
        connection = link
        buffer = Data()
        armTimeout(link)
        link.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, self.connection === link else { return }
            switch state {
            case .failed, .cancelled:
                self.fail("The secure connection to \(peer.name) ended.")
            default:
                break
            }
        }
        TrustedPeerTransport.authenticate(connection: link, peer: peer) { authorized in
            self.queue.async {
                guard self.connection === link else { return }
                guard authorized else {
                    self.fail("The PC rejected this pairing. Check that this iPhone is selected in Porthole on the PC.")
                    return
                }
                guard TrustedPeerStore.load()?.samePairing(as: peer) == true else {
                    self.fail("The paired PC changed before the transfer started.", retry: false)
                    return
                }
                self.write(Data("PSHR \(version) \(self.batch.count)\n".utf8), on: link) {
                    self.sendFile(at: 0, on: link)
                }
            }
        }
    }

    private func sendFile(at cursor: Int, on link: NWConnection) {
        guard connection === link else { return }
        guard TrustedPeerStore.load()?.samePairing(as: peer) == true else {
            fail("The paired PC changed. Review the new destination before sending.", retry: false)
            return
        }
        guard cursor < batch.count else {
            write(Data("DONE\n".utf8), on: link) {
                self.readLine(on: link) { response in
                    if response == "BYE" { self.sent(sessionClosed: true) }
                    else { self.fail("The PC did not confirm the transfer session.") }
                }
            }
            return
        }
        let item = files[batch[cursor]]
        do { activeHandle = try FileHandle(forReadingFrom: item.url) }
        catch { fail("Unable to read \(item.name)."); return }
        let header: String
        switch protocolVersion {
        case 3: header = "ITEM \(item.ticket) \(item.digest) \(item.bytes) \(item.name)\n"
        case 2: header = "ITEM \(item.ticket) FILE \(item.bytes) \(item.name)\n"
        default: header = "FILE \(item.bytes) \(item.name)\n"
        }
        write(Data(header.utf8), on: link) {
            if (self.protocolVersion ?? 1) < 2 { self.pump(at: cursor, left: item.bytes, on: link); return }
            self.readLine(on: link) { response in
                if response == "SAVED" { self.accept(cursor, on: link); return }
                guard response.hasPrefix("OFFSET "), let offset = Int64(response.dropFirst(7)),
                      (0...item.bytes).contains(offset) else { self.fail("The PC could not resume \(item.name)."); return }
                do { try self.activeHandle?.seek(toOffset: UInt64(offset)) }
                catch { self.fail("Unable to read \(item.name)."); return }
                self.pump(at: cursor, left: item.bytes - offset, on: link)
            }
        }
    }

    private func pump(at cursor: Int, left: Int64, on link: NWConnection) {
        guard connection === link else { return }
        let item = files[batch[cursor]]
        if left == 0 {
            try? activeHandle?.close(); activeHandle = nil
            awaitingReceipt = true
            readLine(on: link) { response in
                if response == "OK" { self.accept(cursor, on: link) }
                else { self.fail("The PC did not confirm saving \(item.name).") }
            }
            return
        }
        do {
            guard let chunk = try activeHandle?.read(upToCount: Int(min(left, 1 << 20))), !chunk.isEmpty else {
                fail("Unable to finish reading \(item.name)."); return
            }
            if Int64(chunk.count) == left { awaitingReceipt = true }
            write(chunk, on: link) {
                let remaining = left - Int64(chunk.count)
                let now = DispatchTime.now()
                if now.uptimeNanoseconds - self.lastProgressAt.uptimeNanoseconds >= 150_000_000 {
                    self.lastProgressAt = now
                    let part = Double(item.bytes - remaining) / Double(item.bytes)
                    let fraction = min(0.99, (Double(self.acknowledged.count) + part) / Double(self.files.count))
                    self.updateStatus("Sending \(item.name)…", progress: fraction)
                }
                self.pump(at: cursor, left: remaining, on: link)
            }
        } catch { fail("Unable to read \(item.name).") }
    }

    private func accept(_ cursor: Int, on link: NWConnection) {
        awaitingReceipt = false
        try? activeHandle?.close(); activeHandle = nil
        let index = batch[cursor]
        let item = files[index]
        guard let journal = ShareReceiptJournal.shared(), let batch = journalBatch, var manifest else {
            fail("The PC saved this file. Porthole could not record the receipt. Retry to check it again.")
            return
        }
        do {
            try journal.record(ShareReceipt(id: item.id, date: Date(), peerName: manifest.destination.name,
                                            name: item.name, bytes: item.bytes,
                                            pairingID: manifest.destination.stableID))
            manifest.files[index].sent = true
            try batch.save(manifest)
        } catch {
            fail("The PC saved this file. Porthole could not record the receipt. Retry to check it again.")
            return
        }
        self.manifest = manifest
        acknowledged.insert(index)
        DispatchQueue.main.async { self.onSaved(index) }
        updateStatus("Saved \(item.name) on your PC.", progress: Double(acknowledged.count) / Double(files.count))
        sendFile(at: cursor + 1, on: link)
    }

    private func write(_ data: Data, on link: NWConnection, then completion: @escaping () -> Void) {
        guard connection === link else { return }
        if journalBatch?.isRevoked == true {
            fail("This transfer was removed when its PC was forgotten.", retry: false)
            return
        }
        armTimeout(link)
        link.send(content: data, completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link, self.connection === link else { return }
            if error != nil { self.fail("The connection was interrupted during the transfer.") }
            else { completion() }
        })
    }

    private func readLine(on link: NWConnection, then completion: @escaping (String) -> Void) {
        armTimeout(link)
        readLineFragment(on: link, then: completion)
    }

    private func readLineFragment(on link: NWConnection, then completion: @escaping (String) -> Void) {
        guard connection === link else { return }
        if let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= 128,
                  let text = String(data: buffer.prefix(upTo: newline), encoding: .ascii) else { fail("Invalid PC response."); return }
            buffer.removeSubrange(buffer.startIndex...newline)
            completion(text)
            return
        }
        guard buffer.count <= 128 else { fail("Invalid PC response."); return }
        link.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self, weak link] data, _, complete, error in
            guard let self, let link, self.connection === link else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if (complete || error != nil) && !self.buffer.contains(10) { self.fail("The PC connection closed before confirmation.") }
            else { self.readLineFragment(on: link, then: completion) }
        }
    }

    private func armTimeout(_ link: NWConnection) {
        deadline?.cancel()
        let timer = DispatchWorkItem { [weak self, weak link] in
            guard let self, let link, self.connection === link else { return }
            self.fail("The PC stopped responding.")
        }
        deadline = timer
        queue.asyncAfter(deadline: .now() + 30, execute: timer)
    }

    private func disconnect() {
        savedPCSearch?.cancel()
        savedPCSearch = nil
        deadline?.cancel(); deadline = nil
        let link = connection
        connection = nil
        link?.cancel()
        try? activeHandle?.close(); activeHandle = nil
        buffer = Data()
    }

    private func fail(_ text: String, retry: Bool = true) {
        guard !stopped else { return }
        if !files.isEmpty, acknowledged.count == files.count { sent(sessionClosed: false); return }
        let canRetry = retry && !files.isEmpty
        let uncertain = awaitingReceipt && (protocolVersion ?? 1) < 2
        awaitingReceipt = false
        disconnect()
        if !canRetry { stop() }
        let message = uncertain ? "\(text) The last file may have been saved. Check the PC before retrying." : text
        updateStatus(message, announce: true)
        DispatchQueue.main.async { self.onAction(canRetry ? "Retry remaining files" : "Close", canRetry) }
    }

    private func sent(sessionClosed: Bool) {
        let destination = peer.name
        let count = files.count
        let result = sessionClosed ? "Saved \(count) \(count == 1 ? "file" : "files") on \(destination)."
            : "All files were saved on \(destination). The connection closed before the session confirmation."
        stop()
        updateStatus(result, progress: 1, announce: true)
        DispatchQueue.main.async { self.onAction("Done", false) }
    }

    private func stop() {
        stopped = true
        preparation.cancel()
        disconnect()
        if (manifest?.pendingCount ?? 0) == 0 { try? journalBatch?.discard() }
        journalBatch = nil
        manifest = nil
    }

    private final class Preparation {
        private let lock = NSLock()
        private var token: UUID?
        private var progress: Progress?
        private var stopped = false

        var cancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        func beginItem() -> UUID {
            lock.lock(); defer { lock.unlock() }
            let item = UUID()
            token = item
            return item
        }

        func install(_ task: Progress, for item: UUID) {
            lock.lock()
            let shouldCancel = stopped || token != item
            if !shouldCancel { progress = task }
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func isCancelled(_ item: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped || token != item
        }

        func finishItem(_ item: UUID) {
            lock.lock(); defer { lock.unlock() }
            if token == item { token = nil; progress = nil }
        }

        func cancel() {
            lock.lock()
            stopped = true
            let task = progress
            progress = nil
            token = nil
            lock.unlock()
            task?.cancel()
        }
    }
}
