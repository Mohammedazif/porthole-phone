import Foundation

enum WidgetDestination: String, CaseIterable {
    case connect, received, transfer, share, send, clipboard

    static let scheme = "porthole-widget"

    var url: URL { URL(string: "\(Self.scheme)://open/\(rawValue)")! }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme, parts.host == "open",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.hasPrefix("/") else { return nil }
        self.init(rawValue: String(parts.percentEncodedPath.dropFirst()))
    }
}

/// The app publishes counts and coarse state only. File and peer details remain in the app.
struct WidgetInboxSnapshot: Codable, Equatable {
    static let kind = "PortholeInbox"

    enum Pairing: String, Codable { case unknown, unpaired, paired, disconnected }

    enum ReceivePhase: String, Codable {
        case receiving, saving, interrupted, failed

        var inProgress: Bool { self == .receiving || self == .saving }
    }

    struct Transfer: Codable, Equatable {
        var phase: ReceivePhase
        var reportedAt: Date

        var expiresAt: Date? { phase.inProgress ? reportedAt.addingTimeInterval(10 * 60) : nil }

        func shouldRefresh(for newPhase: ReceivePhase, at date: Date) -> Bool {
            newPhase != phase || (newPhase.inProgress && date.timeIntervalSince(reportedAt) >= 60)
        }
    }

    var unreadCount = 0
    var hasReceivedFiles = false
    var pairing = Pairing.unknown
    var transfer: Transfer?
    var hideLockScreenDetails = true

    var isPaired: Bool { pairing == .paired || pairing == .disconnected }

    static let preview = Self(unreadCount: 3, hasReceivedFiles: true, pairing: .paired, hideLockScreenDetails: false)

    func summary(at date: Date, exposed: Bool = false, redacted: Bool = false) -> WidgetInboxSummary {
        if redacted || (exposed && hideLockScreenDetails) { return .privateReceived }
        if unreadCount > 0 { return .unread(unreadCount) }
        if let transfer {
            if let expiresAt = transfer.expiresAt, date >= expiresAt { return .transferStatusUnknown }
            return transfer.phase.inProgress ? .receiving : .transferNeedsAttention
        }
        if pairing == .unknown { return .open }
        if pairing == .unpaired && !hasReceivedFiles { return .pair }
        return hasReceivedFiles ? .caughtUp : .empty
    }
}

enum WidgetInboxSummary: Equatable {
    case open, privateReceived, pair, empty, caughtUp, receiving, transferStatusUnknown, transferNeedsAttention, unread(Int)

    var title: String {
        switch self {
        case .open: return "Open Porthole"
        case .privateReceived: return "Received files"
        case .pair: return "Pair your PC"
        case .empty: return "No files yet"
        case .caughtUp: return "All caught up"
        case .receiving: return "Transfer started"
        case .transferStatusUnknown: return "Transfer status"
        case .transferNeedsAttention: return "Check transfer"
        case .unread(let count): return count == 1 ? "1 new file" : "\(Self.displayCount(count)) new files"
        }
    }

    var action: String {
        switch self {
        case .open, .pair: return "Connect"
        case .receiving, .transferStatusUnknown, .transferNeedsAttention: return "View transfer"
        case .privateReceived, .empty, .caughtUp, .unread: return "Received"
        }
    }

    var destination: WidgetDestination {
        switch self {
        case .open, .pair: return .connect
        case .receiving, .transferStatusUnknown, .transferNeedsAttention: return .transfer
        case .privateReceived, .caughtUp, .empty, .unread: return .received
        }
    }

    static func displayCount(_ count: Int) -> String {
        count > 999 ? "999+" : count.formatted()
    }
}

struct WidgetInboxStore {
    let container: URL

    static func shared() -> Self? {
        #if os(iOS)
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "PortholeWidgetAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else { return nil }
        return Self(container: container)
        #else
        return nil
        #endif
    }

    private var directory: URL { container.appendingPathComponent("Widgets", isDirectory: true) }
    private var file: URL { directory.appendingPathComponent("Inbox.json") }

    func load() -> WidgetInboxSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 4_097), bytes.count <= 4_096,
              let snapshot = try? JSONDecoder().decode(WidgetInboxSnapshot.self, from: bytes),
              snapshot.unreadCount >= 0 else { return nil }
        return snapshot
    }

    func save(_ snapshot: WidgetInboxSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        #if os(iOS)
        var target = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
}
