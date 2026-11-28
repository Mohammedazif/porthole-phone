import CryptoKit
import Network
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers
import UserNotifications

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
    private var handingOff = false
    /// Sending now: the main button stops it.
    private var sendingNow = false
    private lazy var notice: UIStackView = Self.card()
    private let noticeTitle = UILabel()
    private let noticeBody = UILabel()
    private var finished = false
    private var closing = false
    private var started = false

    // Porthole's own card over the sharing app: it opens at half height, drags
    // up to full height, and drags down (or a tap outside) to cancel.
    private let dim = UIView()
    private let card = UIView()
    private var cardTop: NSLayoutConstraint?
    private var expanded = false
    private var dragging = false
    private var dragStart: CGFloat = 0

    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .overFullScreen
    }

    private var halfTop: CGFloat { max(view.safeAreaInsets.top + 8, view.bounds.height * 0.45) }
    private var fullTop: CGFloat { view.safeAreaInsets.top + 8 }

    private func placeCard(expanded: Bool, animated: Bool) {
        self.expanded = expanded
        cardTop?.constant = expanded ? fullTop : halfTop
        guard animated else { view.layoutIfNeeded(); return }
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) { self.view.layoutIfNeeded() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the card at its height as the screen size or safe area settles.
        guard !closing, !dragging, view.bounds.height > 0, let top = cardTop else { return }
        let wanted = expanded ? fullTop : halfTop
        if top.constant != wanted { top.constant = wanted }
    }

    @objc private func dragCard(_ pan: UIPanGestureRecognizer) {
        guard let top = cardTop, !closing else { return }
        switch pan.state {
        case .began:
            dragging = true
            dragStart = top.constant
        case .changed:
            top.constant = max(fullTop, dragStart + pan.translation(in: view).y)
        case .ended, .cancelled:
            dragging = false
            let velocity = pan.velocity(in: view).y
            if top.constant > halfTop + 90 || (velocity > 900 && !expanded) {
                close()
            } else if velocity < -500 || top.constant < (halfTop + fullTop) / 2 {
                placeCard(expanded: true, animated: true)
            } else {
                placeCard(expanded: false, animated: true)
            }
        default:
            break
        }
    }

    @objc private func toggleCard() {
        placeCard(expanded: !expanded, animated: true)
    }

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
        view.backgroundColor = .clear
        preferredContentSize = CGSize(width: 420, height: 600)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dim.alpha = 0
        dim.isAccessibilityElement = true
        dim.accessibilityLabel = "Cancel sending"
        dim.accessibilityTraits = .button
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        dim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dim)
        card.backgroundColor = .systemGroupedBackground
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.2
        card.layer.shadowRadius = 18
        card.accessibilityViewIsModal = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        let grabber = UIView()
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.isAccessibilityElement = true
        grabber.accessibilityLabel = "Resize"
        grabber.accessibilityTraits = .button
        grabber.accessibilityHint = "Shows the sheet at full or half height."
        grabber.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(grabber)
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

        // Shown when photos or videos are too large to send from here.
        noticeTitle.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        noticeTitle.adjustsFontForContentSizeCategory = true
        noticeTitle.numberOfLines = 0
        noticeBody.font = .preferredFont(forTextStyle: .subheadline)
        noticeBody.adjustsFontForContentSizeCategory = true
        noticeBody.textColor = .secondaryLabel
        noticeBody.numberOfLines = 0
        let noticeText = UIStackView(arrangedSubviews: [noticeTitle, noticeBody])
        noticeText.axis = .vertical
        noticeText.spacing = 4
        noticeText.layoutMargins = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        noticeText.isLayoutMarginsRelativeArrangement = true
        notice.addArrangedSubview(noticeText)
        notice.isHidden = true

        let details = UIStackView(arrangedSubviews: [files, notice, destination])
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
        card.addSubview(body)
        // The grab handle and the header row move the card.
        for handle in [grabber, header] as [UIView] {
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragCard(_:))))
        }
        grabber.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleCard)))
        let top = card.topAnchor.constraint(equalTo: view.topAnchor)
        cardTop = top
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            top,
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grabber.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            grabber.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),
            body.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 10),
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

    /// iOS hosts the extension in its own sheet, and since iOS 26 the views
    /// above ours paint that sheet opaque. Clearing every one of them lets the
    /// sharing app show above the card.
    private func clearHostBackground() {
        var host: UIView? = view
        while let current = host {
            current.backgroundColor = .clear
            current.isOpaque = false
            host = current.superview
        }
        view.window?.backgroundColor = .clear
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        clearHostBackground()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        clearHostBackground()
        guard !started else { return }
        started = true
        UIView.animate(withDuration: 0.25) { self.dim.alpha = 1 }
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
        if let name = TrustedPeer.computerName(peer.name) { titleLabel.text = "Send to \(name)" }
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
                                         self.sendingNow = false
                                         self.readyToSend = retry
                                         self.finished = !retry
                                         self.statusDot.isHidden = title != "Done"
                                         self.configureButton(title, enabled: true)
                                     })
        transfer.onHandoff = { [weak self] in self?.presentHandoff($0) }
        self.transfer = transfer
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        transfer.prepare(providers)
    }

    private func configureButton(_ title: String, enabled: Bool, secondary: Bool = false) {
        // The prominent system glass style is available on iOS 26. A filled
        // capsule provides the same hierarchy on the deployment target.
        var configuration = secondary ? UIButton.Configuration.gray() : UIButton.Configuration.filled()
        #if compiler(>=6.2)
        if #available(iOS 26, *) { configuration = secondary ? .glass() : .prominentGlass() }
        #endif
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        configuration.title = title
        if !secondary {
            configuration.baseBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(white: 0.08, alpha: 1) }
            configuration.baseForegroundColor = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
        } else {
            configuration.baseForegroundColor = .systemRed
        }
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
        if sendingNow {
            sendingNow = false
            button.isEnabled = false
            transfer?.stopSending()
            return
        }
        if handingOff {
            button.isEnabled = false
            transfer?.handOff { [weak self] in self?.close() }
            return
        }
        guard readyToSend else { return }
        readyToSend = false
        sendingNow = true
        configureButton("Cancel sending", enabled: true, secondary: true)
        transfer?.send()
    }

    @objc private func close() {
        guard !closing else { return }
        closing = true
        transfer?.cancel()
        cardTop?.constant = view.bounds.height
        UIView.animate(withDuration: 0.25, animations: {
            self.dim.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
    }

    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    private func presentFiles(_ items: [ShareTransfer.Item]) {
        guard !closing else { return }
        for (index, item) in items.enumerated() {
            let tile = thumbnail(for: item.name, url: item.url)
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

    /// iOS's thumbnail for the item, over Porthole's file-type tile until
    /// (and unless) iOS has one.
    private func thumbnail(for name: String, url: URL?, image known: UIImage? = nil) -> UIView {
        let tile = FileTile(fileExtension: (name as NSString).pathExtension)
        let holder = UIView()
        holder.isAccessibilityElement = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        let image = UIImageView()
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 8
        image.layer.cornerCurve = .continuous
        image.isHidden = true
        image.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(tile)
        holder.addSubview(image)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 44),
            holder.heightAnchor.constraint(equalToConstant: 44),
            tile.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            tile.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            image.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            image.topAnchor.constraint(equalTo: holder.topAnchor),
            image.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        if let known {
            image.image = known
            image.isHidden = false
            tile.isHidden = true
        } else if let url {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 44, height: 44),
                                                       scale: UIScreen.main.scale, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let picture = representation?.uiImage else { return }
                DispatchQueue.main.async {
                    image.image = picture
                    image.isHidden = false
                    tile.isHidden = true
                }
            }
        }
        return holder
    }

    /// Photos or videos too large to copy here: offer to send them with Porthole.
    private func presentHandoff(_ items: [ShareTransfer.Handoff]) {
        guard !closing else { return }
        for (index, item) in items.enumerated() {
            let name = UILabel()
            name.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .medium))
            name.adjustsFontForContentSizeCategory = true
            name.lineBreakMode = .byTruncatingMiddle
            name.text = item.name
            let size = UILabel()
            size.font = .preferredFont(forTextStyle: .footnote)
            size.adjustsFontForContentSizeCategory = true
            size.textColor = .secondaryLabel
            size.text = item.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            size.isHidden = item.bytes == nil
            let labels = UIStackView(arrangedSubviews: [name, size])
            labels.axis = .vertical
            labels.spacing = 1
            let row = UIStackView(arrangedSubviews: [thumbnail(for: item.name, url: nil, image: item.thumbnail), labels])
            row.alignment = .center
            row.spacing = 12
            row.layoutMargins = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
            row.isLayoutMarginsRelativeArrangement = true
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
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
        let videos = ["mov", "mp4", "m4v", "hevc"]
        let allVideos = items.allSatisfy { videos.contains(($0.name as NSString).pathExtension.lowercased()) }
        if items.count == 1 {
            noticeTitle.text = allVideos ? "This video is too large to send from here" : "This item is too large to send from here"
        } else {
            noticeTitle.text = "These items are too large to send from here"
        }
        noticeBody.text = "Send with Porthole instead. You can leave Porthole while it sends."
        notice.isHidden = false
        status.text = "Paired PC"
        handingOff = true
        configureButton("Send with Porthole", enabled: true)
        UIAccessibility.post(notification: .announcement, argument: noticeTitle.text)
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
        var source: TransferSource = .staged
        var isMedia = false
        var ticket: String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    }

    /// A photo or video that doesn't fit as a copy here: Porthole sends it
    /// from the Photo Library instead.
    struct Handoff {
        let name: String
        let bytes: Int64?
        var thumbnail: UIImage? = nil
    }

    /// iOS's thumbnail for a file that is about to go away (waits briefly).
    fileprivate static func quickThumbnail(_ url: URL) -> UIImage? {
        let done = DispatchSemaphore(value: 0)
        var picture: UIImage?
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 120), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            picture = representation?.uiImage
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
        return picture
    }

    private enum Outcome { case item(Item), handoff(Handoff) }

    private enum ShareError: LocalizedError {
        case noSpace
        var errorDescription: String? { "There isn’t enough space on this iPhone to send this file from here." }
    }

    private let peer: TrustedPeer
    private let onFiles: @MainActor ([Item]) -> Void
    private let onStatus: @MainActor (String, Double?, Bool) -> Void
    private let onSaved: @MainActor (Int) -> Void
    private let onAction: @MainActor (String, Bool) -> Void
    var onHandoff: (@MainActor ([Handoff]) -> Void)?
    private var handoffs: [Handoff] = []
    /// Files app originals read in place, kept open while the sheet is.
    private var scopedURLs: [URL] = []
    private let queue = DispatchQueue(label: "porthole.share")
    private let preparation = Preparation()
    private var connection: NWConnection?
    private var savedPCSearch: SavedPCConnection?
    private var deadline: DispatchWorkItem?
    private var activeHandle: FileHandle?
    /// Version 4: the checksum of the file being sent, taken as it goes.
    private var bodyHash: SHA256?
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

    /// Closing mid-send keeps what's left for Porthole: iOS gives a Share
    /// Sheet no time once it closes, so Porthole continues it (with its
    /// progress on the Lock Screen) when the person taps the notice.
    func cancel() {
        preparation.cancel()
        queue.async {
            let sending = self.connection != nil && !self.stopped && (self.manifest?.pendingCount ?? 0) > 0
            let next = self.files.indices.first { !self.acknowledged.contains($0) }.map { self.files[$0].name }
            self.stop()
            guard sending, let next else { return }
            let content = UNMutableNotificationContent()
            content.title = "Sending paused"
            content.body = "Tap to continue sending \(next) in Porthole."
            content.sound = .default
            content.userInfo = ["porthole.send": "resume"]
            content.threadIdentifier = "porthole.send"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "porthole.send.resume",
                                                                        content: content, trigger: nil))
        }
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
            if !handoffs.isEmpty {
                // The whole selection goes to Porthole, together.
                // Thumbnails for the first few only: each takes a moment.
                let all = handoffs + files.filter(\.isMedia).enumerated().map { index, file in
                    Handoff(name: file.name, bytes: file.bytes,
                            thumbnail: index < 6 ? Self.quickThumbnail(file.url) : nil)
                }
                handoffs = all
                let list = all
                DispatchQueue.main.async { self.onHandoff?(list) }
                return
            }
            let originals = files
            let manifest = OutboundTransferManifest(id: batch.id, destination: peer.remembered,
                                                    files: files.map { item in
                .init(id: item.id, name: item.name, bytes: item.bytes, digest: item.digest,
                      sent: false, generatedName: item.generatedName,
                      source: item.source.isStaged ? nil : item.source)
            })
            do {
                let reviewed = try batch.saveSelection(manifest, version: peer.receiveVersion)
                files = reviewed.files.enumerated().map { index, file in
                    // An original is read from where it is; a copy from this batch.
                    let url = file.isStaged ? batch.itemURL(named: file.name, index: index) : originals[index].url
                    return Item(url: url, name: file.name, bytes: file.bytes, digest: file.digest, id: file.id,
                                generatedName: file.generatedName == true, source: file.source ?? .staged,
                                isMedia: originals[index].isMedia)
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
        let activity = ActivityClock()
        updateStatus("Preparing file \(index + 1) of \(providers.count)…")
        // Prepared inside the provider callback: a temporary item expires
        // when the callback returns.
        let finish: (Result<Outcome, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped, !self.preparation.isCancelled(token) else { return }
                self.preparation.finishItem(token)
                switch result {
                case .success(.item(let item)):
                    self.files.append(item)
                    self.collect(providers, at: index + 1, in: directory,
                                 remaining: remaining - (item.source.isStaged ? item.bytes : 0))
                case .success(.handoff(let handoff)):
                    self.handoffs.append(handoff)
                    self.collect(providers, at: index + 1, in: directory, remaining: remaining)
                case .failure(let error):
                    self.fail("Could not prepare item \(index + 1). \(error.localizedDescription)", retry: false)
                }
            }
        }
        let progress: Progress
        if provider.hasRepresentationConforming(toTypeIdentifier: type.identifier, fileOptions: [.openInPlace]) {
            progress = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, inPlace, error in
                guard let self, !self.preparation.isCancelled(token) else { return }
                finish(self.load(url, inPlace: inPlace, error: error, provider: provider, type: type, index: index,
                                 directory: itemDirectory, remaining: remaining, batch: batch, token: token,
                                 activity: activity))
            }
        } else {
            progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, error in
                guard let self, !self.preparation.isCancelled(token) else { return }
                finish(self.load(url, inPlace: false, error: error, provider: provider, type: type, index: index,
                                 directory: itemDirectory, remaining: remaining, batch: batch, token: token,
                                 activity: activity))
            }
        }
        preparation.install(progress, for: token)
        watchPreparation(token, progress: progress, activity: activity, seen: progress.completedUnitCount)
    }

    /// One item, as the provider handed it over:
    /// - a Files original is sent from where it is, nothing copied;
    /// - anything else is copied, if the copy leaves room on the iPhone;
    /// - a photo or video that doesn't fit (or that iOS couldn't hand over)
    ///   goes to Porthole, which sends it from the Photo Library.
    private func load(_ url: URL?, inPlace: Bool, error providerError: Error?, provider: NSItemProvider, type: UTType,
                      index: Int, directory: URL, remaining: Int64, batch: OutboundTransferJournal.Batch,
                      token: UUID, activity: ActivityClock) -> Result<Outcome, Error> {
        let media = type.conforms(to: .movie) || type.conforms(to: .image)
        guard let url else {
            guard media else { return .failure(providerError ?? CocoaError(.fileReadNoSuchFile)) }
            let base = provider.suggestedName ?? "Item \(index + 1)"
            let ext = type.preferredFilenameExtension.map { ".\($0)" } ?? ""
            let name = (base as NSString).pathExtension.isEmpty ? base + ext : base
            return .success(.handoff(Handoff(name: name, bytes: nil)))
        }
        return Result {
            let (name, generated) = Self.wireName(provider.suggestedName, url: url, type: type, index: index)
            let cancelled = { () -> Bool in
                activity.touch() // called for each chunk read
                return self.preparation.isCancelled(token) || batch.isRevoked
            }
            if inPlace {
                let scoped = url.startAccessingSecurityScopedResource()
                if let bookmark = try? url.bookmarkData() {
                    if scoped { queue.async { self.scopedURLs.append(url) } }
                    // A PC that takes the checksum after the file needs only
                    // the size now: sending starts at once.
                    if peer.receiveVersion >= 4, let bytes = Self.localSize(of: url), bytes > 0 {
                        return .item(Item(url: url, name: name, bytes: bytes, digest: "", generatedName: generated,
                                          source: .file(bookmark: bookmark), isMedia: media))
                    }
                    let reader = try FileBodyReader(url: url)
                    defer { reader.close() }
                    let measured = try TransferMeasure.measure(reader, cancelled: cancelled)
                    return .item(Item(url: url, name: name, bytes: measured.bytes, digest: measured.digest,
                                      generatedName: generated, source: .file(bookmark: bookmark), isMedia: media))
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if let free = TransferMeasure.freeSpace(at: directory), free - size < TransferMeasure.keepFree {
                if media { return .handoff(Handoff(name: name, bytes: size, thumbnail: Self.quickThumbnail(url))) }
                throw ShareError.noSpace
            }
            let target = directory.appendingPathComponent(name)
            let snapshot = try TransferStaging.snapshot(url, to: target, remaining: remaining, reserve: batch.reserve,
                                                        cancelled: cancelled)
            return .item(Item(url: target, name: name, bytes: snapshot.bytes, digest: snapshot.digest,
                              generatedName: generated, isMedia: media))
        }
    }

    /// The size of a file already on this iPhone (not one still in iCloud).
    private static func localSize(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { return nil }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return nil }
        return Int64(size)
    }

    /// Passes the photos and videos to Porthole and tells the person.
    func handOff(then done: @escaping @MainActor () -> Void) {
        queue.async {
            let items = self.handoffs
            guard let container = PortholeAppGroup.containerURL, !items.isEmpty else {
                self.fail("Porthole could not take these items. Send them from Porthole instead.", retry: false)
                return
            }
            let record = ShareHandoff(id: UUID(), date: Date(),
                                      items: items.map { ShareHandoff.Item(name: $0.name, bytes: $0.bytes) })
            do { try ShareHandoff.save(record, in: container) }
            catch {
                self.fail("Porthole could not take these items. Send them from Porthole instead.", retry: false)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Ready to send"
            content.body = items.count == 1 ? "\(items[0].name). Tap to send." : "\(items.count) items from the Share Sheet. Tap to send."
            content.sound = .default
            content.userInfo = ["porthole.send": "handoff"]
            content.threadIdentifier = "porthole.send"
            if let picture = items.first(where: { $0.thumbnail != nil })?.thumbnail,
               let data = picture.jpegData(compressionQuality: 0.8) {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-handoff-\(UUID().uuidString).jpg")
                if (try? data.write(to: file)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "thumbnail", url: file) {
                    content.attachments = [attachment]
                }
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "porthole.send.handoff",
                                                                        content: content, trigger: nil))
            self.stop()
            DispatchQueue.main.async { done() }
        }
    }

    /// Gives up on an item only when nothing has moved for two minutes: a
    /// large file takes as long as it takes to copy or download.
    private func watchPreparation(_ token: UUID, progress: Progress, activity: ActivityClock, seen: Int64) {
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, !self.stopped, !self.preparation.isCancelled(token) else { return }
            let now = progress.completedUnitCount
            if now != seen || activity.idleSeconds < 120 {
                self.watchPreparation(token, progress: progress, activity: activity, seen: now)
                return
            }
            self.fail("A selected file stopped preparing. Open the file in its app and try sharing again.", retry: false)
        }
    }

    private final class ActivityClock {
        private let lock = NSLock()
        private var last = Date()
        func touch() { lock.lock(); last = Date(); lock.unlock() }
        var idleSeconds: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(last)
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
        bodyHash = protocolVersion == 4 ? SHA256() : nil
        let header: String
        switch protocolVersion {
        case 4: header = "ITEM \(item.ticket) FILE \(item.bytes) \(item.name)\n"
        case 3: header = "ITEM \(item.ticket) \(item.digest) \(item.bytes) \(item.name)\n"
        case 2: header = "ITEM \(item.ticket) FILE \(item.bytes) \(item.name)\n"
        default: header = "FILE \(item.bytes) \(item.name)\n"
        }
        write(Data(header.utf8), on: link) {
            if (self.protocolVersion ?? 1) < 2 { self.pump(at: cursor, left: item.bytes, on: link); return }
            // Continuing a large file, the PC first checks what it kept.
            self.readLine(on: link, wait: TransferStaging.receiptWait(item.bytes)) { response in
                if response == "SAVED" { self.accept(cursor, on: link); return }
                guard response.hasPrefix("OFFSET "), let offset = Int64(response.dropFirst(7)),
                      (0...item.bytes).contains(offset) else { self.fail("The PC could not resume \(item.name)."); return }
                if self.bodyHash != nil {
                    // The checksum covers the whole file: read again what the
                    // PC kept, without sending it.
                    self.hashKept(at: cursor, left: offset, on: link)
                    return
                }
                do { try self.activeHandle?.seek(toOffset: UInt64(offset)) }
                catch { self.fail("Unable to read \(item.name)."); return }
                self.pump(at: cursor, left: item.bytes - offset, on: link)
            }
        }
    }

    /// Reads what the PC already has into the checksum, a piece per turn.
    private func hashKept(at cursor: Int, left: Int64, on link: NWConnection, read: Int64 = 0) {
        guard connection === link else { return }
        let item = files[batch[cursor]]
        if left == 0 { pump(at: cursor, left: item.bytes - read, on: link); return }
        armTimeout(link, seconds: 60)
        do {
            let chunk = try autoreleasepool { try activeHandle?.read(upToCount: Int(min(left, 8 << 20))) }
            guard let chunk, !chunk.isEmpty else { fail("Unable to finish reading \(item.name)."); return }
            bodyHash?.update(data: chunk)
            queue.async {
                self.hashKept(at: cursor, left: left - Int64(chunk.count), on: link, read: read + Int64(chunk.count))
            }
        } catch { fail("Unable to read \(item.name).") }
    }

    private func pump(at cursor: Int, left: Int64, on link: NWConnection) {
        guard connection === link else { return }
        let item = files[batch[cursor]]
        if left == 0, let hash = bodyHash {
            // Version 4: the checksum follows the last byte.
            bodyHash = nil
            try? activeHandle?.close(); activeHandle = nil
            awaitingReceipt = true
            let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
            write(Data("SUM \(hex)\n".utf8), on: link) { self.pump(at: cursor, left: 0, on: link) }
            return
        }
        if left == 0 {
            try? activeHandle?.close(); activeHandle = nil
            awaitingReceipt = true
            // The PC checks and saves the whole file before it answers.
            readLine(on: link, wait: TransferStaging.receiptWait(item.bytes)) { response in
                if response == "OK" { self.accept(cursor, on: link) }
                else { self.fail("The PC did not confirm saving \(item.name).") }
            }
            return
        }
        do {
            let chunk = try autoreleasepool { try activeHandle?.read(upToCount: Int(min(left, 1 << 20))) }
            guard let chunk, !chunk.isEmpty else {
                fail("Unable to finish reading \(item.name)."); return
            }
            if Int64(chunk.count) == left, bodyHash == nil { awaitingReceipt = true }
            bodyHash?.update(data: chunk)
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

    private func readLine(on link: NWConnection, wait seconds: Double = 30, then completion: @escaping (String) -> Void) {
        armTimeout(link, seconds: seconds)
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

    private func armTimeout(_ link: NWConnection, seconds: Double = 30) {
        deadline?.cancel()
        let timer = DispatchWorkItem { [weak self, weak link] in
            guard let self, let link, self.connection === link else { return }
            self.fail("The PC stopped responding.")
        }
        deadline = timer
        queue.asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    private func disconnect() {
        savedPCSearch?.cancel()
        savedPCSearch = nil
        deadline?.cancel(); deadline = nil
        let link = connection
        connection = nil
        link?.cancel()
        try? activeHandle?.close(); activeHandle = nil
        bodyHash = nil
        buffer = Data()
    }

    /// The person cancelled. What the PC already saved stays sent; what
    /// arrived of the rest is deleted there, and nothing continues it.
    func stopSending() {
        queue.async {
            guard !self.stopped else { return }
            let unsent = self.files.indices.filter { !self.acknowledged.contains($0) }.map { self.files[$0].id }
            if (TrustedPeerStore.load()?.receiveVersion ?? 0) >= 4,
               let destination = TrustedPeerStore.fileSharePeer(matching: self.peer) {
                TransferDrop.send(unsent, to: destination)
            }
            try? self.journalBatch?.discard()
            self.fail("Sending cancelled. Items already sent stay on \(self.peer.name).", retry: false)
        }
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
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs = []
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
