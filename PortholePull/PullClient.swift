import Combine
import Foundation
import ImageIO
import CryptoKit
import Network
import Photos
import UIKit
import UniformTypeIdentifiers
import UserNotifications

extension Notification.Name {
    static let portholeOpenReceived = Notification.Name("porthole.openReceived")
    static let portholeSendNotice = Notification.Name("porthole.sendNotice")
}

enum PhoneNotice {
    static let enabledKey = "porthole.fileNotificationsEnabled"
    private static let body = "A received file is ready."

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func fileArrived(_ file: ReceivedFileReference) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Porthole"
        content.body = body
        content.sound = .default
        content.userInfo = ["file": file.name]
        if let reference = try? JSONEncoder().encode(file) { content.userInfo["reference"] = reference }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.add(request) { error in
            guard error == nil, !enabled else { return }
            center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
            center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
        }
    }

    /// A photo or video dragged to the PC from the shared screen. Quiet (no
    /// sound, no lit screen: the person is watching the PC), and grouped so
    /// several drags stack into one entry.
    static func originalSent(_ name: String, to pc: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sent to \(pc)"
        content.body = name
        content.threadIdentifier = "porthole.drag"
        content.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "porthole.drag.\(UUID().uuidString)",
                                                                    content: content, trigger: nil))
    }

    static func removePreviousFileAlerts() {
        let center = UNUserNotificationCenter.current()
        func shouldRemove(_ request: UNNotificationRequest) -> Bool {
            request.content.userInfo["file"] is String && (!enabled || request.content.body != body)
        }
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.filter(shouldRemove).map(\.identifier))
            center.getDeliveredNotifications { notifications in
                center.removeDeliveredNotifications(withIdentifiers: notifications.map(\.request)
                    .filter(shouldRemove).map(\.identifier))
            }
        }
    }
}

final class NoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoticeDelegate()
    private static var pendingFiles: [ReceivedFileReference] = []
    private static var pendingSendAction: SendNotice.Action?

    static func takeSendAction() -> SendNotice.Action? {
        defer { pendingSendAction = nil }
        return pendingSendAction
    }

    static func takePendingFiles() -> [ReceivedFileReference] {
        defer { pendingFiles.removeAll() }
        return pendingFiles
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The in-app glass arrival banner is the foreground presentation.
        completionHandler(PhoneNotice.enabled ? [.list] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { completionHandler(); return }
        let payload = response.notification.request.content.userInfo
        if let action = (payload[SendNotice.key] as? String).flatMap(SendNotice.Action.init(rawValue:)) {
            DispatchQueue.main.async {
                Self.pendingSendAction = action
                NotificationCenter.default.post(name: .portholeSendNotice, object: nil)
                completionHandler()
            }
            return
        }
        let reference = (payload["reference"] as? Data)
            .flatMap { try? JSONDecoder().decode(ReceivedFileReference.self, from: $0) }
            ?? (payload["file"] as? String).flatMap { ReceivedFileWriter.validName($0) ? ReceivedFileReference(name: $0) : nil }
        DispatchQueue.main.async {
            if let reference {
                Self.pendingFiles.append(reference)
                NotificationCenter.default.post(name: .portholeOpenReceived, object: nil)
            }
            completionHandler()
        }
    }
}

final class PullClient: ObservableObject {
    @Published var status = ""
    @Published var address = ""
    @Published private(set) var linked = false
    /// The PC's hostname, as advertised on this Wi-Fi.
    @Published private(set) var deviceName = ""
    @Published private(set) var clipStatus = ""
    @Published private(set) var clipboardSyncEnabled = true
    private let clipboardPreference = ClipboardSyncPreference()
    private var inputPreference = InputControlPreference()
    private var expectedInputReceipt: String?
    private var requestedInputID: String?
    private var inputVerification: InputVerificationAttempt?
    private var inputVerificationTimer: DispatchWorkItem?
    private var expectedClipboardReceipt: String?
    private var proposedClipboardGeneration: Int?
    private var acceptedClipboardGeneration: Int?
    private var clipboardReceiptTimer: DispatchWorkItem?
    private var pairingKey: String?
    private var savedPCSearch: SavedPCConnection?
    private var pairingCommitted = false
    private var enrolling = false
    private var pendingPairingCapabilities: [String] = []
    private var originalReceipt: (id: UUID, name: String, bytes: Int64)?
    private var originalTimer: DispatchWorkItem?
    private var sendingOriginal = false
    private var originalBodyQueued = false
    private var originalEarlyReceipt: Bool?
    private var originalDownload: PhotoExportStaging?
    private var originalAccessMonitor: DispatchSourceTimer?
    private var choiceTimer: DispatchWorkItem?
    private final class MatchCancellation {
        private let lock = NSLock()
        private var stopped = false
        func cancel() { lock.lock(); stopped = true; lock.unlock() }
        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
    }
    private var matchCancellation: MatchCancellation?
    private struct DeferredLine {
        let text: String
        let queued: (() -> Void)?
    }
    private var deferredLines: [DeferredLine] = []
    @Published private(set) var clipboardLinkReady = false
    @Published private(set) var inputControlsEnabled = true
    @Published private(set) var inputScreenSharingOnly = true
    @Published private(set) var inputControlSupported = false
    @Published private(set) var inputSettingsApplied = false
    @Published private(set) var inputVerificationSupported = false
    @Published private(set) var inputVerificationStatus: InputVerificationStatus = .required
    struct Arrival: Equatable {
        var id = UUID()
        var name: String
        var file: URL?
        var reference: ReceivedFileReference? = nil
        var warning: String? = nil
    }
    @Published var arrival: Arrival?
    struct ReceiveProgress: Equatable {
        typealias Phase = WidgetInboxSnapshot.ReceivePhase
        let transferID: String
        let name: String
        let bytes: Int
        let received: Int
        let phase: Phase
        /// The PC's own name, as everywhere else in Porthole.
        var from = "PC"

        var message: String {
            switch phase {
            case .receiving: return "Receiving from \(from)"
            case .saving: return "Saving to Files"
            case .interrupted: return "Transfer interrupted. It continues when \(from) is back."
            case .failed: return "Unable to save the file. Check available storage, then send it again from \(from)."
            }
        }
    }
    @Published private(set) var receiveProgress: ReceiveProgress?
    @Published private(set) var choiceIDs: [String] = []
    /// Files and copies that moved between this iPhone and the PC, newest first.
    typealias ActivityItem = ActivityRecord
    @Published private(set) var history: [ActivityItem] = []
    @Published private(set) var saveFolderName = "On My iPhone › Porthole"
    @Published private(set) var usesCustomSaveFolder = false
    @Published private(set) var unreadReceived = 0
    @Published private(set) var fileNotificationsEnabled = PhoneNotice.enabled
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus?
    private var requestingNotificationPermission = false
    private let widgetInbox = WidgetInboxPublisher()
    private var hasReceivedFiles = UserDefaults.standard.bool(forKey: "porthole.hasReceivedFiles")
    @Published var activityMessage = ""
    @Published var storageMessage = ""
    @Published private(set) var clipboardHistoryEnabled = UserDefaults.standard.bool(forKey: "porthole.clipboardHistory")
    // Access historyRecords and its load state only on historyQueue.
    private var historyLoaded = false
    private var historyRecords: [ActivityItem] = []
    private var historyAllowsClipboard = UserDefaults.standard.bool(forKey: "porthole.clipboardHistory")
    private let fileQueue = DispatchQueue(label: "porthole.files")
    private let fileStorage: ReceivedFileStorage = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return ReceivedFileStorage(defaultFolder: docs,
                                   legacyDefaultFolder: docs.appendingPathComponent("Porthole", isDirectory: true),
                                   previewFolder: FileManager.default.temporaryDirectory.appendingPathComponent("PortholePreviews", isDirectory: true))
    }()
    private let historyStore: ActivityHistoryStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return ActivityHistoryStore(root: support.appendingPathComponent("PortholeActivity", isDirectory: true))
    }()
    private let queue = DispatchQueue(label: "porthole.pull")
    private var connection: NWConnection?
    private var buffer = Data()
    private var greeted = false
    private var transportPeer: TrustedPeer?
    private var handshakeTimer: DispatchWorkItem?
    private var waitingForLocalNetwork = false
    private var frameTimer: DispatchWorkItem?
    private var inputReceiptTimer: DispatchWorkItem?
    private var matching = false
    private let matchQueue = DispatchQueue(label: "porthole.match", qos: .userInitiated)
    private let clipboardImageQueue = DispatchQueue(label: "porthole.clipboard.images", qos: .userInitiated)
    private let historyQueue = DispatchQueue(label: "porthole.history", qos: .utility)
    private var requestedPeer: TrustedPeer?
    private var disconnectedByPC = false
    private var connecting = false
    @Published private(set) var fileSendPeer: TrustedPeer?
    @Published private(set) var broadcastStatus: TrustedBroadcastStatus?
    @Published private(set) var sharedPairingReady = false
    private let savedPeerKey = "porthole.secure-peer"
    private let lineLimit = 24 * 1024
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var backgroundAudio: CompanionBackgroundAudio?
    // Experiment: the volume buttons change the PC's volume while sharing with sound there.
    private lazy var volumeRelay = VolumeButtonRelay(
        inactiveReason: { [weak self] in
            // Not `self?.volumeButtonsIdleReason() ?? ...`: nil there means active.
            guard let self else { return "no connection" }
            return self.volumeButtonsIdleReason()
        },
        press: { [weak self] louder in self?.sendVolume(louder ? "up" : "down") },
        stuck: { [weak self] in self?.sendVolume("stuck") },
        note: { [weak self] text in self?.sendVolume("note " + text) })
    // Main thread copy of volumeReady.
    private var volumeLinkReady = false
    private weak var index: PhotoIndex?
    // Accessed only on queue. Explicit selection bypasses visual matching once.
    private var syncReady = false
    // Accessed only on queue. The PC accepts the sound choice.
    private var soundReady = false
    // Accessed only on queue. The PC takes volume button presses.
    private var volumeReady = false
    private var didReclaimStaging = false
    private var receivingRecoveryScheduled = false
    private var foreground = true
    private var exporting = false
    private var bodyLeft = 0
    private var bodyKind: Character = "T"
    private var bodyClipboardGeneration: Int?
    private var body = Data()
    private var pendingData: Data?
    private var pendingClipboardGeneration: Int?
    private var pendingKind: Character = "T"
    private var seenCount = -1
    private var writingRemote = false
    private var lastRemoteClipboardAt: DispatchTime?
    private var decodingRemoteClipboard = false
    private var choicePending = false
    private var pushLeft = 0
    private var pushChunkLeft = 0
    private var chunkedPush = false
    /// The person cancelled the file arriving now: its remaining bytes are
    /// let go until the PC confirms with ENDPUSH.
    private var pushStopping = false
    /// Files cancelled while being saved, read on the saving queue.
    private let cancelledSavesLock = NSLock()
    private var cancelledSaves = Set<String>()
    private var activeObserver: NSObjectProtocol?
    private var lastReceiveProgressAt = DispatchTime(uptimeNanoseconds: 0)
    private var pushStage: IncomingTransferStore.Stage?
    /// The checksum of an incoming file, taken as it arrives, so a large
    /// file isn't read a second time to check it.
    private var pushHasher: SHA256?
    private var pushTransfer: IncomingTransfer?
    private var incomingOperation: UUID?
    private var incomingHeartbeat: DispatchWorkItem?
    // Only the main queue touches UIKit background task identifiers.
    private var receiveBackgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    private let incomingQueue = DispatchQueue(label: "porthole.incoming", qos: .utility)
    private let incomingStore = IncomingTransferStore(root: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PortholeIncoming", isDirectory: true))

    init() {
        saveFolderName = fileStorage.folderName
        usesCustomSaveFolder = fileStorage.usesCustomFolder
        clipboardSyncEnabled = clipboardPreference.generation != nil
        inputControlsEnabled = inputPreference.enabled
        inputScreenSharingOnly = inputPreference.screenSharingOnly
        // iOS starts the Lock Screen progress only while Porthole is open:
        // a file that began arriving in the background gets it now.
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self, let receive = self.receiveProgress, receive.phase == .receiving else { return }
            self.showReceiveProgress(name: receive.name)
        }
    }

    /// Lock Screen and Dynamic Island progress, with iOS's stop button,
    /// for a file arriving from the PC. Main thread.
    private func showReceiveProgress(name: String) {
        guard !BackgroundSend.receiving.isRunning else { return }
        let pc = computerName
        if UIApplication.shared.applicationState == .active {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["porthole.receive.show"])
            BackgroundSend.receiving.begin(title: "Receiving from \(pc)", subtitle: name) { [weak self] byPerson in
                // The stop button cancels. If iOS gives up, Porthole keeps
                // receiving in the background while paired.
                if byPerson { self?.cancelReceive() }
            }
        } else if PhoneNotice.enabled {
            let content = UNMutableNotificationContent()
            content.title = "Receiving from \(pc)"
            content.body = "\(name). Tap to see the progress."
            content.threadIdentifier = "porthole.receive"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "porthole.receive.show",
                                                                        content: content, trigger: nil))
        }
    }

    /// Stops the file arriving from the PC. Cancelled means gone: what
    /// arrived is deleted once the PC confirms, and nothing continues it.
    func cancelReceive() {
        queue.async {
            guard let transfer = self.pushTransfer, self.incomingOperation != nil, !self.pushStopping else { return }
            self.pushStopping = true
            if self.pushStage == nil {
                // All of it arrived and it's being saved: it stops before it
                // lands in the folder, and the PC hears NO then.
                self.cancelledSavesLock.lock()
                self.cancelledSaves.insert(transfer.id)
                self.cancelledSavesLock.unlock()
            }
            self.send("STOP \(transfer.id)\n")
            BackgroundSend.receiving.finish(success: false)
            DispatchQueue.main.async {
                if self.receiveProgress?.transferID == transfer.id { self.setReceiveProgress(nil) }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["porthole.receive.show"])
            }
        }
    }

    var inputControlSummary: String {
        if !linked { return "Disconnected" }
        if !inputControlsEnabled { return "Disabled" }
        if !inputControlSupported || !inputVerificationSupported { return "PC update required" }
        if !inputSettingsApplied { return "Applying settings" }
        if inputVerificationStatus.inProgress { return "Verifying Bluetooth" }
        return inputVerificationStatus == .verified ? "Bluetooth verified" : "Waiting for Bluetooth"
    }

    var canVerifyInput: Bool {
        linked && inputControlsEnabled && inputSettingsApplied && inputVerificationSupported &&
            !inputVerificationStatus.inProgress && inputVerificationStatus != .verified
    }

    func beginInputVerification() {
        guard canVerifyInput, let peer = fileSendPeer else { return }
        let attempt = InputVerificationAttempt()
        let id = attempt.id
        inputVerification = attempt
        inputVerificationStatus = .waiting
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.inputVerification?.id == id else { return }
            self.cancelInputVerification(message: "Bluetooth verification timed out.")
        }
        inputVerificationTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
        queue.async {
            guard self.greeted, self.transportPeer?.id == peer.id else { return }
            guard !self.sendingOriginal else {
                DispatchQueue.main.async {
                    guard self.inputVerification?.id == id else { return }
                    self.endInputVerification(.failed("Try again after the Photos transfer finishes."))
                }
                return
            }
            self.send("IV BEGIN \(id)\n")
        }
    }

    func captureInputVerificationKey(_ usage: Int) {
        guard inputVerificationStatus == .waiting, let id = inputVerification?.id,
              let proof = inputVerification?.acceptKeypadUsage(usage), let peer = fileSendPeer else { return }
        inputVerificationStatus = .confirming
        queue.async {
            guard self.greeted, self.transportPeer?.id == peer.id else { return }
            self.send("IV PROOF \(id) \(proof)\n")
        }
    }

    func cancelInputVerification(message: String? = nil) {
        guard let id = inputVerification?.id else { return }
        if let peer = fileSendPeer {
            queue.async {
                guard self.greeted, self.transportPeer?.id == peer.id else { return }
                self.send("IV CANCEL \(id)\n")
            }
        }
        endInputVerification(message.map(InputVerificationStatus.failed) ?? .required)
    }

    private func endInputVerification(_ status: InputVerificationStatus) {
        inputVerificationTimer?.cancel()
        inputVerificationTimer = nil
        inputVerification = nil
        inputVerificationStatus = status
    }

    func setInputControlsEnabled(_ enabled: Bool) {
        if !enabled {
            cancelInputVerification()
            endInputVerification(.required)
        }
        inputControlsEnabled = enabled
        inputPreference.enabled = enabled
        inputPreference.save()
        sendInputPreferences(restricting: !enabled)
    }

    func setInputScreenSharingOnly(_ enabled: Bool) {
        inputScreenSharingOnly = enabled
        inputPreference.screenSharingOnly = enabled
        inputPreference.save()
        sendInputPreferences(restricting: enabled)
    }

    private func sendInputPreferences(restricting: Bool = false) {
        inputSettingsApplied = false
        guard let peer = fileSendPeer, inputControlSupported else { return }
        let update = inputPreference.update(verificationAvailable: inputVerificationSupported)
        requestedInputID = update.id
        queue.async {
            guard self.greeted, self.transportPeer?.id == peer.id else { return }
            if restricting, self.sendingOriginal {
                self.disconnect(peer, message: "Photos transfer stopped to apply mouse and keyboard settings. Reconnecting…")
                return
            }
            self.expectedInputReceipt = update.receipt
            self.inputReceiptTimer?.cancel()
            self.send(update.command) { [weak self] in
                guard let self, self.expectedInputReceipt == update.receipt else { return }
                self.inputReceiptTimer = self.receiptTimeout(for: peer, message: "The PC did not confirm mouse and keyboard preferences.")
            }
        }
    }

    private func receiptTimeout(for peer: TrustedPeer, message: String) -> DispatchWorkItem {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.transportPeer?.id == peer.id else { return }
            self.disconnect(peer, message: message)
        }
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        return timeout
    }

    var clipboardSummary: String {
        if !clipboardSyncEnabled { return "Disabled" }
        if !linked { return "Waiting for connection" }
        return clipboardLinkReady ? "Enabled · Bidirectional" : "Waiting for PC confirmation"
    }

    func setClipboardSyncEnabled(_ enabled: Bool) {
        guard clipboardSyncEnabled != enabled else { return }
        clipboardPreference.setEnabled(enabled)
        clipboardSyncEnabled = enabled
        clipboardLinkReady = false
        clipStatus = enabled ? "Waiting for PC confirmation." : "Clipboard sync disabled."
        let peerID = fileSendPeer?.id
        queue.async {
            guard let peer = self.transportPeer, peer.id == peerID else { return }
            if !enabled, self.sendingOriginal {
                self.disconnect(peer, message: "Photos transfer stopped to disable clipboard sync. Reconnecting…")
                return
            }
            self.pendingData = nil
            self.pendingClipboardGeneration = nil
            if self.syncReady { self.negotiateClipboard(peer) }
        }
    }

    private func negotiateClipboard(_ peer: TrustedPeer) {
        acceptedClipboardGeneration = nil
        let id = UUID().uuidString.lowercased()
        proposedClipboardGeneration = clipboardPreference.generation
        let value = proposedClipboardGeneration == nil ? 0 : 1
        expectedClipboardReceipt = "SYNC OK \(id) \(value)"
        clipboardReceiptTimer?.cancel()
        send("SYNC \(id) \(value)\n") { [weak self] in
            guard let self, self.expectedClipboardReceipt == "SYNC OK \(id) \(value)" else { return }
            self.clipboardReceiptTimer = self.receiptTimeout(for: peer, message: "The PC did not confirm the clipboard setting.")
        }
    }

    /// Tells the PC where the shared app's sound plays, so both devices show the same choice.
    func setSoundMode(_ mode: SoundMode) {
        queue.async {
            guard self.soundReady else { return }
            self.sendSoundMode(mode)
        }
    }

    // Called on queue.
    private func sendSoundMode(_ mode: SoundMode) {
        guard greeted else { return }
        let id = UUID().uuidString.lowercased()
        send("SOUND \(id) \(mode.rawValue)\n")
    }

    /// Why the volume buttons are the iPhone's own right now, or nil while
    /// they change the PC's volume. Called on main.
    private func volumeButtonsIdleReason() -> String? {
        guard volumeLinkReady else { return "PC did not offer volume" }
        guard linked else { return "not connected" }
        guard TrustedPeerStore.soundMode() == .pc else { return "sound mode \(TrustedPeerStore.soundMode().rawValue)" }
        guard let peer = requestedPeer, let snapshot = TrustedPeerStore.broadcastStatus(),
              snapshot.peerID == peer.stableID else { return "not sharing" }
        guard snapshot.phase == .live || snapshot.phase == .waitingForFrames else {
            return "sharing \(snapshot.phase.rawValue)"
        }
        guard Date().timeIntervalSince(snapshot.updatedAt) < 8 else { return "sharing status old" }
        return nil
    }

    private func sendVolume(_ word: String) {
        queue.async {
            guard self.volumeReady, self.greeted else { return }
            self.send("VOLUME \(word)\n")
        }
    }

    private func sendSystemPhoneName() {
        guard let peer = fileSendPeer,
              let name = Self.displayName(UIDevice.current.name, maxBytes: 63) else { return }
        let hasNameEntitlement = Bundle.main.object(forInfoDictionaryKey: "PortholeDeviceNameEntitlementsSuffix")
            as? String == "-DeviceName"
        guard hasNameEntitlement || name != "iPhone" else { return }
        let announcement = hasNameEntitlement ? "NAME  \(name)\n" : "NAME \(name)\n"
        queue.async {
            if self.transportPeer?.id == peer.id { self.send(announcement) }
        }
    }

    private static func displayName(_ raw: String, maxBytes: Int) -> String? {
        let clean = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        // A name of only blank characters is still the PC's name.
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? clean : trimmed
        var result = ""
        var remaining = maxBytes
        for character in name {
            let length = String(character).utf8.count
            guard length <= remaining else { break }
            result.append(character)
            remaining -= length
        }
        return result.isEmpty ? nil : result
    }

    private func canSendClipboard() -> Bool {
        guard clipboardPreference.generation != nil else {
            clipStatus = "Clipboard sync is disabled."
            return false
        }
        guard linked else {
            clipStatus = "Connect to a PC to transfer clipboard content."
            return false
        }
        guard clipboardLinkReady else { clipStatus = "Waiting for PC confirmation."; return false }
        return true
    }

    /// The user picked one of two similar photos, or neither.
    func pickChoice(_ id: String?) {
        queue.async {
            guard self.choicePending else { return }
            self.choiceTimer?.cancel()
            self.choicePending = false
            DispatchQueue.main.async {
                self.choiceIDs = []
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["porthole.drag.choose"])
            }
            guard let id,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                self.send("MISS\n")
                DispatchQueue.main.async { self.status = "No file sent" }
                return
            }
            self.export(asset, approved: true)
        }
    }

    var widgetReceiveAttention: ReceiveProgress.Phase? {
        guard let phase = widgetInbox.snapshot.transfer?.phase, !phase.inProgress else { return nil }
        return phase
    }

    func dismissReceiveStatus() {
        if widgetReceiveAttention != nil { setReceiveProgress(nil) }
    }

    private func setReceiveProgress(_ progress: ReceiveProgress?) {
        if let phase = progress?.phase {
            let now = Date()
            if widgetInbox.snapshot.transfer?.shouldRefresh(for: phase, at: now) ?? true {
                widgetInbox.update { $0.transfer = .init(phase: phase, reportedAt: now) }
            }
        } else if widgetInbox.snapshot.transfer != nil {
            widgetInbox.update { $0.transfer = nil }
        }
        receiveProgress = progress
    }

    private func publishWidgetPairing() {
        let pairing: WidgetInboxSnapshot.Pairing = linked ? .paired : savedPeer() == nil ? .unpaired : .disconnected
        widgetInbox.update { $0.pairing = pairing }
    }

    func clearArrival() {
        arrival = nil
    }

    func bind(index: PhotoIndex) {
        queue.async { [weak index] in self.index = index }
    }

    func clearHistory() {
        historyQueue.async {
            do {
                if !self.historyLoaded { _ = try? self.historyStore.load() }
                for journal in Self.sendReceiptJournals {
                    for receipt in try journal.pending() { try journal.remove(receipt.id) }
                }
                try self.historyStore.clear()
                self.historyRecords = []
                self.historyLoaded = true
                self.publishHistory()
                self.reportHistory("History cleared. Received files are still in Files.")
            } catch { self.reportHistory("Unable to clear history. Try again.") }
        }
    }

    func removeActivity(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        historyQueue.async {
            guard self.historyLoaded else { return }
            let kept = self.historyRecords.filter { !ids.contains($0.id) }
            do {
                self.historyRecords = try self.historyStore.save(kept)
                self.publishHistory()
            } catch { self.reportHistory("Unable to update activity history.") }
        }
    }

    func setClipboardHistoryEnabled(_ enabled: Bool) {
        clipboardHistoryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "porthole.clipboardHistory")
        historyQueue.async {
            self.historyAllowsClipboard = enabled
            if !enabled { self.loadAndTrimHistory(force: true) }
        }
    }

    func sendActivity(_ item: ActivityItem) {
        guard canSendClipboard(), let peer = fileSendPeer, let revision = clipboardPreference.generation else { return }
        if let text = item.clipboardText { deliverText(text) }
        else if let url = clipboardPreviewURL(item) {
            clipboardImageQueue.async {
                guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 8 * 1024 * 1024 else { return }
                DispatchQueue.main.async {
                    guard self.fileSendPeer?.id == peer.id, self.clipboardPreference.allows(revision) else { return }
                    self.queueClip(kind: "P", data: data)
                    self.clipStatus = "Image queued for transfer."
                }
            }
        }
    }

    /// A notification or file preview can mark just its own receipt.
    func markReceivedRead(_ referenceID: UUID) {
        markReceivedRead { $0.fileReference?.id == referenceID }
    }

    func markReceivedRecordsRead(_ recordIDs: Set<UUID>) {
        markReceivedRead { recordIDs.contains($0.id) }
    }

    private func markReceivedRead(where matches: @escaping (ActivityItem) -> Bool) {
        historyQueue.async {
            var records = self.historyRecords
            let changed = records.indices.filter { records[$0].isUnreadReceivedFile && matches(records[$0]) }
            guard !changed.isEmpty else { return }
            for offset in changed { records[offset].isUnread = false }
            do {
                self.historyRecords = self.historyLoaded ? try self.historyStore.save(records) : records
                self.publishHistory()
            } catch { self.reportHistory("Unable to mark received files as read.") }
        }
    }

    private func publishHistory() {
        let records = historyRecords
        let received = records.filter(\.isReceivedFile)
        let unread = received.filter(\.isUnreadReceivedFile).count
        DispatchQueue.main.async {
            self.history = self.clipboardHistoryEnabled ? records : records.filter(\.isFile)
            self.unreadReceived = unread
            if !received.isEmpty { self.rememberReceivedFiles() }
            self.widgetInbox.update {
                $0.unreadCount = unread
                $0.hasReceivedFiles = self.hasReceivedFiles
            }
        }
    }

    private func rememberReceivedFiles() {
        guard !hasReceivedFiles else { return }
        hasReceivedFiles = true
        UserDefaults.standard.set(true, forKey: "porthole.hasReceivedFiles")
    }

    private func reportHistory(_ message: String) {
        DispatchQueue.main.async { self.activityMessage = message }
    }

    private func loadAndTrimHistory(force: Bool = false) {
        do {
            if !historyLoaded {
                historyRecords = try historyStore.load()
                historyLoaded = true
            }
            let kept = ActivityHistoryStore.retained(historyAllowsClipboard ? historyRecords : historyRecords.filter(\.isFile))
            historyRecords = force || kept != historyRecords ? try historyStore.save(kept) : kept
            publishHistory()
        } catch { reportHistory("Saved activity could not be updated. Existing received files are unchanged.") }
    }

    private func loadHistory() { historyQueue.async { self.loadAndTrimHistory() } }

    private static var sendReceiptJournals: [ShareReceiptJournal] {
        OutboundFileSender.storageContainers.map(ShareReceiptJournal.init(containerURL:))
    }

    func importSentReceipts() {
        historyQueue.async {
            guard self.historyLoaded else { return }
            for journal in Self.sendReceiptJournals {
                do {
                    journal.pruneImported()
                    let receipts = try journal.pending()
                    guard !receipts.isEmpty else { continue }
                    let existing = Set(self.historyRecords.map(\.id))
                    var merged = self.historyRecords
                    for receipt in receipts where !existing.contains(receipt.id) {
                        merged.append(ActivityItem(id: receipt.id, date: receipt.date, title: receipt.name,
                                                   detail: "Sent to \(receipt.peerName)", isFile: true, incoming: false, bytes: receipt.bytes))
                    }
                    merged.sort { $0.date > $1.date }
                    self.historyRecords = try self.historyStore.save(merged)
                    self.publishHistory()
                    for receipt in receipts { try journal.markImported(receipt.id) }
                } catch { self.reportHistory("Sent activity could not be imported. Porthole will retry.") }
            }
        }
    }

    func chooseSaveFolder(_ url: URL) {
        fileQueue.async {
            do {
                try self.fileStorage.chooseFolder(url)
                self.reportSaveFolder("Save folder updated. Existing files stay in their original folders.")
            } catch {
                DispatchQueue.main.async { self.storageMessage = error.localizedDescription }
            }
        }
    }

    func resetSaveFolder() {
        fileQueue.async {
            self.fileStorage.resetFolder()
            self.reportSaveFolder("New received files will be saved in Porthole.")
        }
    }

    private func reportSaveFolder(_ message: String) {
        let name = fileStorage.folderName
        let custom = fileStorage.usesCustomFolder
        DispatchQueue.main.async {
            self.saveFolderName = name
            self.usesCustomSaveFolder = custom
            self.storageMessage = message
        }
    }

    func openReceived(_ reference: ReceivedFileReference, completion: @escaping (Result<URL, Error>) -> Void) {
        fileQueue.async {
            let result = Result { try self.fileStorage.prepareForReading(reference) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func releaseReceivedPreview(_ url: URL) { fileQueue.async { self.fileStorage.releasePreview(url) } }

    func canCopy(_ item: ActivityItem) -> Bool {
        item.clipboardText != nil || item.clipboardImage.flatMap(historyStore.clipboardImageURL) != nil
    }

    func clipboardPreviewURL(_ item: ActivityItem) -> URL? {
        item.clipboardImage.flatMap(historyStore.clipboardImageURL)
    }

    func copyActivity(_ item: ActivityItem, completion: @escaping (Bool) -> Void) {
        guard clipboardHistoryEnabled else {
            activityMessage = "Clipboard history is disabled."
            completion(false)
            return
        }
        if let text = item.clipboardText {
            writeLocalClipboard(type: .utf8PlainText, value: text)
            activityMessage = "Copied to this iPhone. Ready to paste."
            completion(true)
            return
        }
        guard let name = item.clipboardImage, let url = historyStore.clipboardImageURL(name) else {
            activityMessage = "The full content of this clipboard item is unavailable."
            completion(false)
            return
        }
        clipboardImageQueue.async {
            let data = try? Data(contentsOf: url)
            DispatchQueue.main.async {
                guard self.clipboardHistoryEnabled, self.history.contains(where: { $0.id == item.id }),
                      let data, (1...8 * 1024 * 1024).contains(data.count) else {
                    self.activityMessage = "The clipboard image is unavailable."
                    completion(false)
                    return
                }
                self.writeLocalClipboard(type: .png, value: data)
                self.activityMessage = "Copied to this iPhone. Ready to paste."
                completion(true)
            }
        }
    }

    var canStartBroadcast: Bool { fileSendPeer != nil && sharedPairingReady }

    func matchesReviewedPairing(_ peer: TrustedPeer) -> Bool {
        requestedPeer?.samePairing(as: peer) == true
    }

    var savedPC: TrustedPeer? { widgetShortcutPairing }

    var widgetShortcutPairing: TrustedPeer? { fileSendPeer?.remembered ?? savedPeer() }

    func reconnectForWidgetShortcut(_ peer: TrustedPeer) -> Bool {
        guard !disconnectedByPC, savedPeer()?.samePairing(as: peer) == true else { return false }
        loadSaved()
        guard matchesReviewedPairing(peer) else { return false }
        if !linked && !connecting { connect() }
        return connecting
    }

    var sharedPairingIssue: String? {
        guard fileSendPeer != nil, !sharedPairingReady else { return nil }
        return "This install is missing the App Group for Broadcast and Share. Reinstall with the matching App Group enabled for all three targets."
    }

    private func publishSharedPeer(_ peer: TrustedPeer) {
        sharedPairingReady = TrustedPeerStore.save(peer) && TrustedPeerStore.load() == peer
    }

    func refreshNotificationPermission(promptIfNeeded: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationAuthorization = settings.authorizationStatus
                guard promptIfNeeded, self.foreground, self.fileNotificationsEnabled,
                      settings.authorizationStatus == .notDetermined else { return }
                self.requestNotificationPermission()
            }
        }
    }

    func setFileNotificationsEnabled(_ enabled: Bool) {
        fileNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PhoneNotice.enabledKey)
        if enabled {
            if notificationAuthorization == .notDetermined {
                requestNotificationPermission()
            } else {
                refreshNotificationPermission()
            }
        } else {
            PhoneNotice.removePreviousFileAlerts()
        }
    }

    private func requestNotificationPermission() {
        guard !requestingNotificationPermission else { return }
        requestingNotificationPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async {
                self.requestingNotificationPermission = false
                self.refreshNotificationPermission()
            }
        }
    }

    func refreshBroadcastStatus() {
        guard let snapshot = TrustedPeerStore.broadcastStatus(),
              snapshot.peerID == requestedPeer?.stableID,
              Date().timeIntervalSince(snapshot.updatedAt) < 8 else {
            if broadcastStatus != nil { broadcastStatus = nil }
            return
        }
        if broadcastStatus != snapshot { broadcastStatus = snapshot }
    }

    func requestBroadcastStop() -> Bool {
        guard let peer = requestedPeer,
              let snapshot = TrustedPeerStore.broadcastStatus(), snapshot.peerID == peer.stableID,
              Date().timeIntervalSince(snapshot.updatedAt) < 8 else { return false }
        switch snapshot.phase {
        case .connecting, .live, .waitingForFrames, .reconnecting: break
        default: return false
        }
        return TrustedPeerStore.requestBroadcastStop(peer: peer)
    }



    var computerName: String {
        let peer = fileSendPeer ?? savedPC
        return TrustedPeer.computerName(deviceName) ?? TrustedPeer.computerName(peer?.name) ?? "PC"
    }

    /// Callable from any queue; the list lives on the main thread.
    private func note(_ title: String, _ detail: String, file: Bool, incoming: Bool,
                      path: String? = nil, receivedFile: ReceivedFileReference? = nil,
                      clipboardText: String? = nil, clipboardImage: Data? = nil, bytes: Int64? = nil) {
        DispatchQueue.main.async {
            let shown = detail.replacingOccurrences(of: "the PC", with: self.computerName)
            self.historyQueue.async {
                guard file || self.historyAllowsClipboard else { return }
                let record = ActivityItem(title: title, detail: shown, isFile: file, incoming: incoming,
                                          path: path, receivedFile: receivedFile, clipboardText: clipboardText, bytes: bytes)
                if self.historyLoaded {
                    do {
                        if let clipboardImage {
                            self.historyRecords = try self.historyStore.saveClipboardImage(clipboardImage, record: record,
                                                                                           before: self.historyRecords)
                        } else {
                            self.historyRecords = try self.historyStore.save([record] + self.historyRecords)
                        }
                    } catch { self.reportHistory("Activity could not be saved on this iPhone.") }
                } else {
                    self.historyRecords = ActivityHistoryStore.retained([record] + self.historyRecords)
                    self.reportHistory("Saved activity is unavailable. New activity is shown for this session.")
                }
                self.publishHistory()
            }
        }
    }

    private static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }

    func loadLocalState() {
        loadSaved()
        publishWidgetPairing()
        loadHistory()
        importSentReceipts()
        UserDefaults.standard.removeObject(forKey: "porthole.code")
        if !didReclaimStaging {
            didReclaimStaging = true
            PhoneNotice.removePreviousFileAlerts()
            fileQueue.async {
                self.fileStorage.reclaimOldPreviews()
                TransferStaging.removeExpiredDirectories(in: FileManager.default.temporaryDirectory, prefix: "Original-",
                                                         olderThan: Date().addingTimeInterval(-86400))
            }
        }
        recoverReceivedTransfers()
        fileQueue.async {
            for container in OutboundFileSender.storageContainers {
                OutboundTransferJournal(container: container).reclaimExpired()
            }
        }
    }

    private func recoverReceivedTransfers() {
        guard !receivingRecoveryScheduled else { return }
        receivingRecoveryScheduled = true
        incomingQueue.async {
            for (path, receipt) in self.incomingStore.unimportedReceipts() {
                self.importReceivedReceipt(receipt, at: path)
            }
            for intent in self.incomingStore.pendingStaging() {
                if (try? self.fileStorage.recoverStaging(intent)) != nil {
                    self.incomingStore.completeStaging(intent.id)
                }
            }
            self.incomingStore.reclaimExpired()
            DispatchQueue.main.async { self.receivingRecoveryScheduled = false }
        }
    }

    func cameForward() {
        foreground = true
        backgroundAudio?.setRequested(false)
        volumeRelay.prepare()  // the system slider is built while Porthole is on screen
        volumeRelay.setForeground(true)
        if linked { volumeRelay.start() }
        loadLocalState()
        refreshNotificationPermission(promptIfNeeded: linked)
        refreshBroadcastStatus()
        if linked { sendSystemPhoneName() }
        if !disconnectedByPC, !linked, !connecting, requestedPeer != nil { connect() }
    }

    func enteredBackground() {
        foreground = false
        volumeRelay.setForeground(false)
        cancelInputVerification(message: "Bluetooth verification was interrupted.")
        updateBackgroundConnection()
        if backgroundAudio?.requested == true && !linked && !connecting && reconnectWork == nil {
            scheduleReconnect()
        }
    }

    private func updateBackgroundConnection() {
        if !foreground, !disconnectedByPC, let requestedPeer,
           savedPeer()?.samePairing(as: requestedPeer) == true,
           PairingCredential.load(requestedPeer.credentialProfile) != nil {
            if backgroundAudio == nil { backgroundAudio = CompanionBackgroundAudio() }
            backgroundAudio?.setRequested(true)
            volumeRelay.start()  // keeps running in the foreground too, while linked
        } else {
            backgroundAudio?.setRequested(false)
            if linked { volumeRelay.start() } else { volumeRelay.stop() }
            if !foreground {
                reconnectWork?.cancel()
                reconnectWork = nil
            }
        }
    }

    func sendClipboardNow() {
        considerLocal()
    }

    private static func discardPendingSends(for peer: TrustedPeer) {
        for container in OutboundFileSender.storageContainers {
            OutboundTransferJournal(container: container).discard(for: peer)
        }
    }

    func forgetPC() {
        var forgotten = Set<String>()
        for peer in [requestedPeer, savedPeer(), PendingPairing.load()?.peer].compactMap({ $0 })
            where forgotten.insert(peer.credentialProfile).inserted {
            fileQueue.async { Self.discardPendingSends(for: peer) }
            PairingCredential.remove(peer.credentialProfile)
            PendingPairing.clear(for: peer)
        }
        PairingCredential.remove(savedPeerKey)
        requestedPeer = nil
        backgroundAudio?.setRequested(false)
        reconnectWork?.cancel()
        reconnectWork = nil
        connecting = false
        setDisconnected()
        TrustedPeerStore.clear()
        queue.async { self.resetTransport() }
        address = ""
        UserDefaults.standard.removeObject(forKey: savedPeerKey)
        UserDefaults.standard.removeObject(forKey: "porthole.host")
        UserDefaults.standard.removeObject(forKey: "porthole.code")
        UserDefaults.standard.removeObject(forKey: "porthole.device")
        publishWidgetPairing()
        status = ""
    }

    private func setDisconnected() {
        DiagnosticLog.setSink(nil)
        fileSendPeer = nil
        linked = false
        inputControlSupported = false
        inputSettingsApplied = false
        inputVerificationSupported = false
        endInputVerification(.required)
        choiceIDs = []
        deviceName = ""
        clipStatus = ""
        clipboardLinkReady = false
        requestedInputID = nil
        sharedPairingReady = false
        publishWidgetPairing()
    }

    private func resetTransport() {
        savedPCSearch?.cancel()
        savedPCSearch = nil
        waitingForLocalNetwork = false
        connection?.cancel()
        connection = nil
        transportPeer = nil
        handshakeTimer?.cancel()
        frameTimer?.cancel()
        inputReceiptTimer?.cancel()
        clipboardReceiptTimer?.cancel()
        frameTimer = nil
        originalTimer?.cancel()
        originalReceipt = nil
        clearOriginalDownload()
        originalBodyQueued = false
        originalEarlyReceipt = nil
        choiceTimer?.cancel()
        matchCancellation?.cancel()
        matchCancellation = nil
        expectedClipboardReceipt = nil
        expectedInputReceipt = nil
        pairingKey = nil
        pairingCommitted = false
        enrolling = false
        pendingPairingCapabilities.removeAll()
        sendingOriginal = false
        deferredLines.removeAll()
        greeted = false
        syncReady = false
        soundReady = false
        volumeReady = false
        DispatchQueue.main.async { self.volumeLinkReady = false }
        proposedClipboardGeneration = nil
        acceptedClipboardGeneration = nil
        pendingData = nil
        pendingClipboardGeneration = nil
        choicePending = false
        matching = false
        exporting = false
        buffer.removeAll()
        body.removeAll()
        bodyLeft = 0
        bodyClipboardGeneration = nil
        lastRemoteClipboardAt = nil
        if let interrupted = pushTransfer {
            reportReceive(interrupted, received: interrupted.bytes - pushLeft, phase: .interrupted)
        }
        abortPush()
    }

    /// The UI uses local pairing drafts. Reconnects only use a previously verified identity.
    @discardableResult
    func connect(address rawAddress: String, code rawCode: String, fingerprint rawFingerprint: String? = nil) -> Bool {
        let token = rawCode.filter { !$0.isWhitespace }.uppercased()
        let fingerprint = rawFingerprint.flatMap(TrustedPeer.normalizeFingerprint)
        guard let host = TrustedPeer.pairingHost(rawAddress), token.utf8.count == 8,
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              let fingerprint else {
            status = "Enter a PC address, eight-character code and its SHA-256 certificate fingerprint, or scan its secure QR code."
            return false
        }
        guard !host.contains(":") else {
            status = "Use the IPv4 address shown in Porthole on the PC."
            return false
        }
        let peer = TrustedPeer(host: host, name: host, fingerprint: fingerprint, id: UUID())
        guard PendingPairing.prepare(peer, code: token) else {
            status = "Porthole couldn’t save this pending pairing in the iPhone Keychain."
            return false
        }
        let previous = requestedPeer ?? savedPeer()
        if previous != nil {
            // An explicit pairing replaces any active extension authorization.
            TrustedPeerStore.clear()
            broadcastStatus = nil
        }
        requestedPeer = peer
        reconnectAttempt = 0
        connecting = false
        address = host
        connectCurrentPeer()
        return true
    }

    func connectSavedPC() {
        guard !connecting, let saved = savedPeer() else { return }
        if let pending = PendingPairing.load(), !pending.peer.samePairing(as: saved) {
            PendingPairing.clear(for: pending.peer)
        }
        requestedPeer = saved
        address = saved.host
        reconnectAttempt = 0
        connectCurrentPeer()
    }

    func connect() {
        if reconnectAttempt >= 4, let requestedPeer,
           PendingPairing.load()?.peer.samePairing(as: requestedPeer) == true {
            reconnectAttempt = 1
        }
        connectCurrentPeer()
    }

    private func connectCurrentPeer() {
        guard !connecting, let requestedPeer else { return }
        let profile = requestedPeer.credentialProfile
        let savedKey = PairingCredential.load(profile)
        if !foreground && (backgroundAudio?.requested != true || savedKey == nil) {
            backgroundAudio?.setRequested(false)
            return
        }
        disconnectedByPC = false
        let pending = PendingPairing.load().flatMap { $0.peer.samePairing(as: requestedPeer) ? $0 : nil }
        let pendingKey = pending?.key ?? PairingCredential.load("pending/" + profile)
        let credentials: [String]
        if let savedKey {
            credentials = [savedKey]
        } else if let pending {
            // Retry the bound key after a lost acknowledgement, and the code
            // when the PC never committed the pairing.
            credentials = [pending.activeCode, pending.key].compactMap { $0 }
        } else {
            credentials = [pendingKey, PairingCredential.load("bootstrap/" + profile)].compactMap { $0 }
        }
        guard !credentials.isEmpty else {
            status = "Pair this PC again with its secure QR code."
            return
        }
        let token = credentials[reconnectAttempt % credentials.count]
        let recoverAddress = reconnectAttempt <= 1 || reconnectAttempt % 4 == 0
        let peer = requestedPeer.newSession(host: requestedPeer.host)
        self.requestedPeer = peer
        reconnectWork?.cancel()
        reconnectWork = nil
        connecting = true
        setDisconnected()
        if savedKey != nil {
            TrustedPeerStore.save(peer.remembered)
        }
        status = "Verifying the identity of \(peer.name)…"
        queue.async {
            self.resetTransport()
            self.enrolling = token.utf8.count == 8
            self.pairingKey = token.utf8.count == 32 ? token : pendingKey ?? PairingCredential.getOrCreate("pending/" + profile)
            guard self.pairingKey != nil else {
                self.disconnect(peer, message: "Porthole couldn’t prepare a pairing key. Check the iPhone Keychain and retry.")
                return
            }
            self.transportPeer = peer
            if savedKey != nil {
                let search = SavedPCConnection(peer: peer, port: 47731, queue: self.queue,
                                               recoverAddress: recoverAddress)
                self.savedPCSearch = search
                search.start { [weak self] result in
                    guard let self else { return }
                    self.savedPCSearch = nil
                    switch result {
                    case .success(let destination):
                        self.openTransport(destination.link, to: destination.peer, token: token, ready: true)
                    case .failure(.localNetworkDenied):
                        self.disconnect(peer, message: "Allow Porthole in Settings › Privacy & Security › Local Network, then connect again.", retry: false)
                    case .failure(.unavailable):
                        self.disconnect(peer, message: "Could not reach the saved PC. Check that Porthole is running and both devices are on the same Wi-Fi network.")
                    }
                }
            } else {
                let link = TrustedPeerTransport.connection(to: peer, port: 47731)
                self.openTransport(link, to: peer, token: token, ready: false)
            }
        }
    }

    private func openTransport(_ link: NWConnection, to peer: TrustedPeer, token: String, ready: Bool) {
        transportPeer = peer
        connection = link
        link.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, self.connection === link else { return }
            self.noteLink(state, token: token, peer: peer)
        }
        armHandshakeTimeout(for: link, peer: peer)
        if ready { noteLink(.ready, token: token, peer: peer) }
        else { link.start(queue: queue) }
    }

    private func savedPeer() -> TrustedPeer? {
        let stored = PairingCredential.load(savedPeerKey).map { Data($0.utf8) }
        guard let data = stored ?? UserDefaults.standard.data(forKey: savedPeerKey) else { return nil }
        guard let peer = try? JSONDecoder().decode(TrustedPeer.self, from: data) else { return nil }
        guard peer.pairingID == nil else { return peer }
        let upgraded = peer.remembered
        let oldProfile = "\(peer.host)/\(peer.fingerprint)"
        for prefix in ["", "pending/", "bootstrap/"] {
            if let value = PairingCredential.load(prefix + oldProfile) {
                guard PairingCredential.save(value, for: prefix + upgraded.credentialProfile) else { return peer }
                PairingCredential.remove(prefix + oldProfile)
            }
        }
        if let encoded = try? JSONEncoder().encode(upgraded) {
            UserDefaults.standard.set(encoded, forKey: savedPeerKey)
        }
        return upgraded
    }

    private func armHandshakeTimeout(for link: NWConnection, peer: TrustedPeer) {
        handshakeTimer?.cancel()
        let waiting = waitingForLocalNetwork
        let timeout = DispatchWorkItem { [weak self, weak link] in
            guard let self, let link, self.connection === link, !self.pairingCommitted else { return }
            let message = waiting
                ? "Allow Porthole in Settings › Privacy & Security › Local Network, then connect again."
                : "The PC took too long to respond. Check that Porthole is running and both devices are on the same local network."
            self.disconnect(peer, message: message, retry: !waiting)
        }
        handshakeTimer = timeout
        queue.asyncAfter(deadline: .now() + .seconds(waiting ? 60 : 12), execute: timeout)
    }

    private func noteLink(_ state: NWConnection.State, token: String, peer: TrustedPeer) {
        guard let link = connection else { return }
        switch state {
        case .ready:
            if waitingForLocalNetwork {
                waitingForLocalNetwork = false
                armHandshakeTimeout(for: link, peer: peer)
                DispatchQueue.main.async {
                    guard self.requestedPeer?.id == peer.id, self.connecting else { return }
                    self.status = "Connecting to \(peer.name)…"
                }
            }
            send("HELLO \(token)\n")
            receive()
        case .waiting where link.currentPath?.unsatisfiedReason == .localNetworkDenied:
            if !waitingForLocalNetwork {
                waitingForLocalNetwork = true
                armHandshakeTimeout(for: link, peer: peer)
                DispatchQueue.main.async {
                    guard self.requestedPeer?.id == peer.id, self.connecting else { return }
                    self.status = "Allow Local Network access to connect to this PC."
                }
            }
        case .failed:
            disconnect(peer, message: "Unable to verify or reach this PC. Check that it supports secure pairing and that its certificate is unchanged.")
        default: break
        }
    }

    private func disconnect(_ peer: TrustedPeer, message: String, retry: Bool = true) {
        resetTransport()
        DispatchQueue.main.async {
            guard self.requestedPeer?.id == peer.id else { return }
            self.setDisconnected()
            if let shared = TrustedPeerStore.load(), shared.samePairing(as: peer) {
                TrustedPeerStore.save(shared.remembered)
            }
            self.connecting = false
            self.status = message
            if retry { self.scheduleReconnect() }
            else { self.backgroundAudio?.setRequested(false) }
        }
    }

    private func send(_ text: String, queued: (() -> Void)? = nil) {
        guard let link = connection, let peer = transportPeer else { return }
        if sendingOriginal {
            guard deferredLines.count < 64 else {
                disconnect(peer, message: "The PC sent too many messages during transfer.")
                return
            }
            deferredLines.append(DeferredLine(text: text, queued: queued))
            return
        }
        link.send(content: Data(text.utf8), completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link, self.connection === link, error != nil else { return }
            self.disconnect(peer, message: "The secure connection was interrupted.")
        })
        queued?()
    }

    private func receive() {
        guard let link = connection, let peer = transportPeer else { return }
        link.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak link] data, _, complete, error in
            guard let self, let link, self.connection === link else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain(peer: peer)
            }
            guard self.connection === link else { return }
            if complete || error != nil {
                self.disconnect(peer, message: self.greeted ? "Disconnected. Reconnecting…" : "The PC closed the connection before pairing finished.")
            } else {
                self.receive()
            }
        }
    }

    private func armFrameTimeout(peer: TrustedPeer) {
        guard frameTimer == nil else { return }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.transportPeer?.id == peer.id else { return }
            self.disconnect(peer, message: "The PC did not finish sending a message.")
        }
        frameTimer = timer
        queue.asyncAfter(deadline: .now() + 30, execute: timer)
    }

    private func finishFrameTimer() { frameTimer?.cancel(); frameTimer = nil }

    private func drain(peer: TrustedPeer) {
        while connection != nil {
            if pushChunkLeft > 0 {
                let prior = pushChunkLeft
                guard writePushBody(peer: peer) else { return }
                if prior != pushChunkLeft { finishFrameTimer() }
                if pushChunkLeft > 0 { armFrameTimeout(peer: peer); return }
                if pushLeft == 0 { finishPush() }
            }
            if bodyLeft > 0 {
                let take = min(bodyLeft, buffer.count)
                if take > 0 {
                    if let revision = bodyClipboardGeneration, clipboardPreference.allows(revision) {
                        body.append(buffer.prefix(take))
                    } else {
                        bodyClipboardGeneration = nil
                        body.removeAll()
                    }
                    buffer.removeFirst(take)
                    bodyLeft -= take
                    finishFrameTimer()
                }
                if bodyLeft > 0 { armFrameTimeout(peer: peer); return }
                let payload = body
                let generation = bodyClipboardGeneration
                body.removeAll()
                bodyClipboardGeneration = nil
                applyRemote(kind: bodyKind, data: payload, generation: generation, peer: transportPeer ?? peer)
            }
            guard let newline = buffer.firstIndex(of: 10) else {
                if buffer.count > lineLimit { disconnect(peer, message: "The PC sent an oversized message header.") }
                else if !buffer.isEmpty || pushLeft > 0 { armFrameTimeout(peer: peer) }
                return
            }
            let line = buffer[..<newline]
            guard line.count <= lineLimit, let value = String(data: line, encoding: .utf8) else {
                disconnect(peer, message: "The PC sent an invalid message header.")
                return
            }
            buffer.removeSubrange(...newline)
            finishFrameTimer()
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !greeted {
                if rejectPairing(text, peer: peer) { return }
                if text == "DISCONNECTED" {
                    resetTransport()
                    DispatchQueue.main.async {
                        guard self.requestedPeer?.id == peer.id else { return }
                        self.disconnectedByPC = true
                        self.backgroundAudio?.setRequested(false)
                        self.reconnectWork?.cancel()
                        self.reconnectWork = nil
                        self.setDisconnected()
                        self.connecting = false
                        TrustedPeerStore.clear()
                        self.status = "Disconnected by PC. Select Connect to reconnect."
                    }
                    return
                }
                guard acceptGreeting(text, peer: peer) else {
                    disconnect(peer, message: "The PC must support secure pairing and accept your connection code.")
                    return
                }
                continue
            }
            if !pairingCommitted {
                handle(text)
                continue
            }
            if text.hasPrefix("CLIP ") {
                guard let (kind, length) = clipHeader(text) else {
                    disconnect(peer, message: "The PC sent an invalid clipboard header.")
                    return
                }
                bodyKind = kind
                bodyLeft = length
                bodyClipboardGeneration = acceptedClipboardGeneration
                body.removeAll()
            } else if text.hasPrefix("CHUNK ") {
                guard chunkedPush, pushStage != nil, let count = IncomingTransfer.chunkLength(text, remaining: pushLeft) else {
                    disconnect(peer, message: "The PC sent an invalid file segment.")
                    return
                }
                pushChunkLeft = count
            } else if text.hasPrefix("PUSH2 ") || text.hasPrefix("PUSH3 ") {
                guard let transfer = IncomingTransfer(header: text), incomingOperation == nil else {
                    disconnect(peer, message: "The PC sent an invalid or overlapping file request.")
                    return
                }
                beginPush(transfer, chunked: text.hasPrefix("PUSH3 "))
            } else if text.hasPrefix("PUSH ") {
                disconnect(peer, message: "Update Porthole on your PC to send files securely.")
                return
            } else if text.hasPrefix("ENDPUSH ") {
                // Cancelled here or on the PC: what arrived is deleted.
                if let transfer = pushTransfer, String(text.dropFirst(8)) == transfer.id {
                    let onPC = !pushStopping
                    abortPush(discard: true)
                    if onPC {
                        DispatchQueue.main.async {
                            if self.receiveProgress?.transferID == transfer.id { self.setReceiveProgress(nil) }
                            if self.fileSendPeer?.id == peer.id {
                                self.status = "\(self.computerName) cancelled sending \(transfer.name)."
                            }
                        }
                    }
                }
            } else {
                handle(text)
            }
        }
    }

    private func rejectPairing(_ line: String, peer: TrustedPeer) -> Bool {
        let message: String
        switch line {
        case "PAIR CODE": message = "That code did not match. Use the current code or scan the QR on \(peer.name)."
        case "PAIR SAVED": message = "\(peer.name) has a saved pairing. Choose New code on the PC, then scan the QR."
        case "PAIR CLOSED": message = "Open a new pairing code in Porthole on \(peer.name)."
        case "PAIR LOCKED": message = "Too many attempts. Generate a fresh code on \(peer.name) or wait one minute."
        case "PAIR REVOKED": message = "This pairing was removed on the PC. Scan its current QR code."
        default: return false
        }
        let recover = line == "PAIR SAVED" && enrolling
        resetTransport()
        DispatchQueue.main.async {
            guard self.requestedPeer?.id == peer.id else { return }
            self.connecting = false
            self.setDisconnected()
            self.backgroundAudio?.setRequested(false)
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            if line == "PAIR REVOKED" {
                TrustedPeerStore.clear()
                self.disconnectedByPC = true
            }
            if recover, self.reconnectAttempt == 0,
               PendingPairing.load()?.peer.samePairing(as: peer) == true {
                // Recover a commit whose PAIRED acknowledgement was lost.
                self.reconnectAttempt = 1
                self.connectCurrentPeer()
            } else {
                self.status = message
            }
        }
        return true
    }

    private func acceptGreeting(_ line: String, peer: TrustedPeer) -> Bool {
        let fields = line.split(separator: " ")
        guard (2...3).contains(fields.count), fields[0] == "OK",
              TrustedPeer.isChannelTicket(String(fields[1])) else { return false }
        let advertisedName = fields.count == 3 ? Data(base64Encoded: String(fields[2]))
            .flatMap { String(data: $0, encoding: .utf8) }.flatMap { Self.displayName($0, maxBytes: 63) } : nil
        let name = TrustedPeer.computerName(advertisedName) ?? TrustedPeer.computerName(peer.name) ?? "PC"
        var verified = TrustedPeer(host: peer.host, name: name, fingerprint: peer.fingerprint,
                                   id: peer.id, pairingID: peer.stableID)
        verified.channelTicket = String(fields[1])
        transportPeer = verified
        greeted = true
        send("RESUME?\n")
        // Lines for the PC's log: what happened on this iPhone.
        DiagnosticLog.setSink { [weak self] line in
            self?.queue.async {
                guard let self, self.greeted, !self.sendingOriginal else { return }
                self.send("LOG \(line)\n")
            }
        }
        let kept = DiagnosticLog.takeKept()
        for line in kept.suffix(40) where !sendingOriginal { send("LOG \(line)\n") }
        DiagnosticLog.note("Porthole \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")), bundle \(Bundle.main.bundleIdentifier ?? "?"), iOS \(UIDevice.current.systemVersion)")
        if !enrolling { completePairing(verified) }
        return true
    }

    private func completePairing(_ peer: TrustedPeer) {
        guard let key = pairingKey else { return }
        pairingKey = nil
        pairingCommitted = true
        handshakeTimer?.cancel()
        let remembered = peer.remembered
        DispatchQueue.main.async {
            guard self.requestedPeer?.id == peer.id else { return }
            let previous = self.savedPeer()
            guard let data = try? JSONEncoder().encode(remembered),
                  PairingCredential.save(key, for: peer.credentialProfile),
                  PairingCredential.save(String(decoding: data, as: UTF8.self), for: self.savedPeerKey) else {
                self.queue.async {
                    guard self.transportPeer?.id == peer.id else { return }
                    self.disconnect(peer, message: "Porthole couldn’t save the verified pairing. Retrying…")
                }
                return
            }
            UserDefaults.standard.set(data, forKey: self.savedPeerKey)
            PendingPairing.clear(for: peer)
            if let previous, !previous.samePairing(as: peer) {
                self.fileQueue.async { Self.discardPendingSends(for: previous) }
                PairingCredential.remove(previous.credentialProfile)
                PendingPairing.clear(for: previous)
            }
            self.reconnectAttempt = 0
            self.requestedPeer = peer
            self.connecting = false
            self.fileSendPeer = peer
            self.deviceName = peer.name
            self.address = peer.host
            self.linked = true
            self.status = "Connected securely to \(peer.name)."
            self.updateBackgroundConnection()
            self.publishSharedPeer(peer)
            self.publishWidgetPairing()
            self.sendSystemPhoneName()
            self.refreshNotificationPermission(promptIfNeeded: true)
        }
        if peer.resumable { send("FILES 2\nFILES 3\nQUEUE 1\n") }
        send("INBOX?\nINBOX? 4\nSHARE?\nIV?\nSCREEN? 2\nSCREEN? 3\nSCREEN? 4\n")
        let capabilities = pendingPairingCapabilities
        pendingPairingCapabilities.removeAll()
        for capability in capabilities { handle(capability) }
    }

    private func handle(_ line: String) {
        guard let peer = transportPeer, greeted else { return }
        if line == "PAIRED", !pairingCommitted, peer.resumable {
            completePairing(peer)
            return
        }
        if line == "RESUME 2" {
            guard !peer.resumable else { return }
            var resumable = peer
            resumable.resumable = true
            transportPeer = resumable
            guard pairingCommitted else {
                if let pairingKey { send("PAIR \(pairingKey)\n") }
                return
            }
            send("FILES 2\nFILES 3\nQUEUE 1\n")
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == resumable.id else { return }
                self.fileSendPeer = resumable
                self.publishSharedPeer(resumable)
            }
            return
        }
        guard pairingCommitted else {
            if line == "SYNC READY" || line == "INPUT READY" || line == "SOUND READY" || line == "VOLUME READY",
               !pendingPairingCapabilities.contains(line) {
                pendingPairingCapabilities.append(line)
            }
            return
        }
        if line.hasPrefix("SHAREKEY ") {
            let ticket = String(line.dropFirst("SHAREKEY ".count))
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == peer.id else { return }
                TrustedPeerStore.saveFileShareTicket(ticket, for: peer)
            }
            return
        }
        if line.hasPrefix("SCREENKEY ") {
            let ticket = String(line.dropFirst("SCREENKEY ".count))
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == peer.id else { return }
                TrustedPeerStore.saveScreenTicket(ticket, for: peer)
            }
            return
        }
        if line == "INBOX 3" || line == "INBOX 4" {
            // An older PC never answers INBOX? 4.
            var capable = peer
            capable.inboxVersion = max(capable.inboxVersion ?? 0, line == "INBOX 4" ? 4 : 3)
            transportPeer = capable
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == capable.id else { return }
                self.fileSendPeer = capable
                self.publishSharedPeer(capable)
            }
            return
        }
        if line == "SCREEN 2" || line == "SCREEN 3" || line == "SCREEN 4" {
            // The PC answers SCREEN? 2, 3 and 4 in order, so the last answer is the
            // highest it supports. An older PC never answers 4 and gets version 3.
            var capable = peer
            capable.broadcastVersion = Int(line.dropFirst("SCREEN ".count)) ?? 2
            transportPeer = capable
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == capable.id else { return }
                self.fileSendPeer = capable
                self.publishSharedPeer(capable)
            }
            return
        }
        if line == "INPUT READY" {
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == peer.id, !self.inputControlSupported else { return }
                self.inputControlSupported = true
                self.sendInputPreferences()
            }
            return
        }
        if line == "IV READY" {
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == peer.id, !self.inputVerificationSupported else { return }
                self.inputVerificationSupported = true
                self.sendInputPreferences()
            }
            return
        }
        if line.hasPrefix("IV ") {
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == peer.id, self.inputVerificationSupported else { return }
                if line == "IV RESET" {
                    let status: InputVerificationStatus = self.inputVerificationStatus.inProgress
                        ? .failed("The Bluetooth connection changed. Try again.")
                        : .required
                    self.endInputVerification(status)
                    return
                }
                if line == "IV VERIFIED", self.inputControlsEnabled {
                    self.endInputVerification(.verified)
                    return
                }
                guard let id = self.inputVerification?.id else { return }
                if line == "IV OK \(id)", self.inputVerificationStatus == .confirming, self.inputControlsEnabled {
                    self.endInputVerification(.verified)
                } else if line == "IV FAILED \(id)" {
                    self.endInputVerification(.failed("The selected PC could not verify its Bluetooth connection."))
                }
            }
            return
        }
        if line == expectedInputReceipt {
            expectedInputReceipt = nil
            inputReceiptTimer?.cancel()
            let id = line.split(separator: " ")[2]
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == peer.id, self.requestedInputID == String(id) else { return }
                self.inputSettingsApplied = true
            }
            return
        }
        if line == "VOLUME READY" {
            volumeReady = true
            DispatchQueue.main.async { self.volumeLinkReady = true }
            return
        }
        if line == "SOUND READY" {
            soundReady = true
            sendSoundMode(TrustedPeerStore.soundMode())
            return
        }
        // Chosen on the PC. The broadcast extension and Settings read the saved choice.
        if line.hasPrefix("SOUND SET "), let mode = SoundMode(rawValue: String(line.dropFirst("SOUND SET ".count))) {
            TrustedPeerStore.setSoundMode(mode)
            return
        }
        if line == "SYNC READY" {
            guard !syncReady else { return }
            syncReady = true
            negotiateClipboard(peer)
            return
        }
        if line == expectedClipboardReceipt {
            expectedClipboardReceipt = nil
            clipboardReceiptTimer?.cancel()
            let enabled = line.hasSuffix(" 1")
            acceptedClipboardGeneration = proposedClipboardGeneration
            DispatchQueue.main.async {
                guard self.fileSendPeer?.id == peer.id, self.clipboardSyncEnabled == enabled else { return }
                self.clipboardLinkReady = enabled
                self.clipStatus = enabled ? "Clipboard sync connected." : "Clipboard sync disabled."
            }
            flushClip()
            return
        }
        if line == "CLIP?" {
            guard let generation = acceptedClipboardGeneration, clipboardPreference.allows(generation) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.foreground, self.fileSendPeer?.id == peer.id else { return }
                self.answerClipAsk(tries: 6, peerID: peer.id, generation: generation)
            }
            return
        }
        if let receipt = originalReceipt, originalBodyQueued {
            let id = receipt.id.uuidString.lowercased()
            if line == "RECEIVED \(id)" || line == "REJECTED \(id)" {
                let saved = line.hasPrefix("RECEIVED ")
                if sendingOriginal { originalEarlyReceipt = saved }
                else { finishOriginal(peer, saved: saved) }
                return
            }
        }
        if line == "CANCEL PULL" {
            // The desktop drains and rejects any FILE2 body already in flight.
            guard !sendingOriginal, originalReceipt == nil, matching || choicePending || exporting else { return }
            matchCancellation?.cancel()
            matchCancellation = nil
            choiceTimer?.cancel()
            originalTimer?.cancel()
            clearOriginalDownload()
            matching = false
            choicePending = false
            exporting = false
            send("MISS cancelled\n")
            DispatchQueue.main.async {
                if self.fileSendPeer?.id == peer.id { self.choiceIDs = [] }
            }
            return
        }
        guard greeted, line.hasPrefix("PULL ") else { return }
        guard !matching, !exporting, !choicePending else { return }
        let parts = line.split(separator: " ")
        guard (3...6).contains(parts.count), let hash = UInt64(parts[1], radix: 16),
              let aspect = Double(parts[2]), aspect.isFinite, (0.05...20).contains(aspect) else {
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
        guard parts.count < 4 || thumb != nil, parts.count < 5 || detail != nil,
              parts.count < 6 || screen != nil else { send("MISS invalid-preview\n"); return }
        guard thumb != nil || screen != nil else { send("MISS preview-required\n"); return }
        matchOriginal(index: index, hash: hash, aspect: aspect, thumb: thumb,
                      detail: detail, screen: screen, peer: peer)
    }

    private func matchOriginal(index: PhotoIndex, hash: UInt64, aspect: Double, thumb: [Double]?,
                               detail: [Double]?, screen: PhotoIndex.Screen?, peer: TrustedPeer) {
        matching = true
        let cancellation = MatchCancellation()
        matchCancellation = cancellation
        DispatchQueue.main.async {
            guard !cancellation.cancelled else { return }
            switch index.prepareMatch() {
            case .ready:
                if self.fileSendPeer?.id == peer.id { self.status = "Identifying photo or video" }
                self.runPhotoMatch(index: index, hash: hash, aspect: aspect, thumb: thumb,
                                   detail: detail, screen: screen, peer: peer, cancellation: cancellation)
                return
            case .preparing:
                self.rejectUnreadyPhotoMatch(peer, cancellation: cancellation, reason: "photo-library-preparing",
                                            message: "Preparing your photo library. Check Photo access, then try again.")
            case .accessRequired:
                self.rejectUnreadyPhotoMatch(peer, cancellation: cancellation, reason: "photo-access-required",
                                            message: "Allow Photo access on your iPhone before identifying an original.")
            }
        }
    }

    private func rejectUnreadyPhotoMatch(_ peer: TrustedPeer, cancellation: MatchCancellation, reason: String, message: String) {
        queue.async {
            guard self.transportPeer?.id == peer.id, self.matchCancellation === cancellation else { return }
            self.matching = false
            self.matchCancellation = nil
            self.send("MISS \(reason)\n")
            DispatchQueue.main.async { if self.fileSendPeer?.id == peer.id { self.status = message } }
        }
    }

    private func runPhotoMatch(index: PhotoIndex, hash: UInt64, aspect: Double, thumb: [Double]?,
                              detail: [Double]?, screen: PhotoIndex.Screen?, peer: TrustedPeer, cancellation: MatchCancellation) {
        matchQueue.async {
            let found = index.match(hash: hash, aspect: aspect, thumb: thumb, detail: detail, screen: screen,
                                    isCancelled: { cancellation.cancelled }) { [weak self] text in
                DispatchQueue.main.async { [weak self] in
                    if !cancellation.cancelled, self?.fileSendPeer?.id == peer.id { self?.status = text }
                }
            }
            self.queue.async {
                guard self.transportPeer?.id == peer.id, self.greeted,
                      self.matchCancellation === cancellation else { return }
                self.matching = false
                self.matchCancellation = nil
                if found.asset == nil, !found.choices.isEmpty {
                    self.askToSendOriginal(found.choices, to: peer)
                } else if let asset = found.asset {
                    // One sure match goes straight to the PC, as it used to:
                    // the person is in Photos and can't see a question here.
                    // An edited item still asks first (export checks that).
                    self.export(asset)
                } else {
                    self.send(found.videoUnavailable ? "MISS video-unavailable\n" : "MISS \(found.closest)\n")
                    DispatchQueue.main.async {
                        guard self.fileSendPeer?.id == peer.id else { return }
                        self.status = found.videoUnavailable
                            ? "Some videos couldn’t be compared. Send it with Send files › Photo Library instead."
                            : "Unable to identify this item. Send it with Send files › Photo Library instead."
                    }
                }
            }
        }
    }

    private func askToSendOriginal(_ ids: [String], to peer: TrustedPeer) {
        choicePending = true
        DispatchQueue.main.async {
            guard self.fileSendPeer?.id == peer.id else { return }
            self.choiceIDs = ids
            self.status = ids.count == 1 ? "Confirm transfer of the unedited original." : "Select the original to transfer."
            // The person is dragging on the PC, likely in Photos: ask where
            // they'll see it. Opening Porthole shows the choice.
            guard UIApplication.shared.applicationState != .active, PhoneNotice.enabled else { return }
            let content = UNMutableNotificationContent()
            content.title = ids.count == 1 ? "Send the original to \(self.computerName)?" : "Choose the photo to send"
            content.body = ids.count == 1 ? "This item was edited. Tap to send its original."
                                          : "Some photos look alike. Tap to choose the one to send to \(self.computerName)."
            content.sound = .default
            content.threadIdentifier = "porthole.drag"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "porthole.drag.choose",
                                                                        content: content, trigger: nil))
        }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.transportPeer?.id == peer.id, self.choicePending else { return }
            self.choicePending = false
            self.send("MISS confirmation-expired\n")
            DispatchQueue.main.async {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["porthole.drag.choose"])
                guard self.fileSendPeer?.id == peer.id else { return }
                self.choiceIDs = []
                self.status = "Original transfer confirmation expired."
            }
        }
        choiceTimer = timer
        // Long enough to see the notification, open Porthole and choose; the
        // PC waits up to five minutes.
        queue.asyncAfter(deadline: .now() + 120, execute: timer)
    }

    private func export(_ proposedAsset: PHAsset, approved: Bool = false) {
        guard let peer = transportPeer, let link = connection, greeted, !exporting else { return }
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard permission == .authorized || permission == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [proposedAsset.localIdentifier], options: nil).firstObject else {
            send("MISS selected-item-unavailable\n")
            return
        }
        let resources = PHAssetResource.assetResources(for: asset)
        if !approved, resources.contains(where: { $0.type == .adjustmentData || $0.type == .adjustmentBasePhoto || $0.type == .adjustmentBaseVideo }) {
            askToSendOriginal([asset.localIdentifier], to: peer)
            return
        }
        let type: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        guard let resource = resources.first(where: { $0.type == type }) else { send("MISS\n"); return }
        let name = TransferFileName.make(resource.originalFilename, index: 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Original-" + UUID().uuidString, isDirectory: true)
        let stage: PhotoExportStaging
        do { stage = try PhotoExportStaging(file: directory.appendingPathComponent(name), sourceIdentifier: asset.localIdentifier) }
        catch { send("MISS storage-unavailable\n"); return }
        originalDownload = stage
        exporting = true
        let monitor = DispatchSource.makeTimerSource(queue: queue)
        monitor.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        monitor.setEventHandler { [weak self, weak stage] in
            guard let self, let stage, self.originalDownload === stage,
                  !stage.canReadSource(verifyExistence: true) else { return }
            self.cancelRevokedOriginal(stage, peer: peer)
        }
        originalAccessMonitor = monitor
        monitor.resume()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        armOriginalDeadline(stage, peer: peer)
        DispatchQueue.main.async {
            if self.fileSendPeer?.id == peer.id { self.status = "Preparing \(name) for transfer" }
        }
        stage.start(resource: resource, options: options) { [weak self, weak stage] size in
            guard let self, let stage else { return }
            self.queue.async {
                guard self.connection === link, self.originalDownload === stage else { return }
                self.originalTimer?.cancel()
                guard stage.canReadSource(verifyExistence: true) else {
                    self.cancelRevokedOriginal(stage, peer: peer)
                    return
                }
                guard let size else {
                    self.failOriginalPreparation(stage, peer: peer, reason: "Unable to read the original from Photos.")
                    return
                }
                self.streamOriginal(stage, name: name, size: size, peer: peer, link: link)
            }
        }
    }

    /// A large original (often downloaded from iCloud first) takes as long
    /// as it takes; only a minute with no data from Photos gives up.
    private func armOriginalDeadline(_ stage: PhotoExportStaging, peer: TrustedPeer) {
        let deadline = DispatchWorkItem { [weak self, weak stage] in
            guard let self, let stage, self.originalDownload === stage else { return }
            if stage.idleSeconds < 60 {
                self.armOriginalDeadline(stage, peer: peer)
                return
            }
            self.failOriginalPreparation(stage, peer: peer, reason: "Original preparation stopped.")
        }
        originalTimer = deadline
        queue.asyncAfter(deadline: .now() + 60, execute: deadline)
    }

    private func clearOriginalDownload() {
        originalAccessMonitor?.cancel()
        originalAccessMonitor = nil
        originalDownload?.cancel()
        originalDownload = nil
    }

    private func cancelRevokedOriginal(_ stage: PhotoExportStaging, peer: TrustedPeer) {
        let reason = "This original is no longer available in your photo library. Transfer stopped."
        if sendingOriginal {
            // The PC is still reading the FILE2 body. Close the link so it discards a partial file.
            disconnect(peer, message: reason)
        } else {
            failOriginalPreparation(stage, peer: peer, reason: reason)
        }
    }

    private func failOriginalPreparation(_ stage: PhotoExportStaging, peer: TrustedPeer, reason: String) {
        guard originalDownload === stage else { return }
        originalTimer?.cancel()
        clearOriginalDownload()
        exporting = false
        send("MISS unavailable\n")
        DispatchQueue.main.async { if self.fileSendPeer?.id == peer.id { self.status = reason } }
    }

    private func streamOriginal(_ stage: PhotoExportStaging, name: String, size: Int64, peer: TrustedPeer, link: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: stage.file) else {
            failOriginalPreparation(stage, peer: peer, reason: "Unable to open the original for transfer.")
            return
        }
        let id = UUID()
        originalReceipt = (id, name, size)
        originalBodyQueued = false
        originalEarlyReceipt = nil
        send("FILE2 \(id.uuidString.lowercased()) \(size) \(name)\n")
        sendingOriginal = true
        func next(remaining: Int64) {
            guard self.connection === link, self.originalDownload === stage else { try? handle.close(); return }
            if remaining == 0 {
                try? handle.close()
                self.clearOriginalDownload()
                self.sendingOriginal = false
                let commands = self.deferredLines
                self.deferredLines.removeAll()
                for command in commands { self.send(command.text, queued: command.queued) }
                self.flushClip()
                if let saved = self.originalEarlyReceipt { self.finishOriginal(peer, saved: saved); return }
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.transportPeer?.id == peer.id, self.originalReceipt?.id == id else { return }
                    self.finishOriginal(peer, saved: nil)
                }
                self.originalTimer = timer
                self.queue.asyncAfter(deadline: .now() + 30, execute: timer)
                return
            }
            guard stage.canReadSource() else {
                try? handle.close()
                self.cancelRevokedOriginal(stage, peer: peer)
                return
            }
            do {
                let chunk = try autoreleasepool { try handle.read(upToCount: Int(min(remaining, 1 << 19))) }
                guard let chunk, !chunk.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                self.originalBodyQueued = Int64(chunk.count) == remaining
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.connection === link, self.sendingOriginal else { return }
                    self.disconnect(peer, message: "Original transfer was interrupted.")
                }
                self.originalTimer?.cancel()
                self.originalTimer = timer
                self.queue.asyncAfter(deadline: .now() + 10, execute: timer)
                link.send(content: chunk, completion: .contentProcessed { error in
                    guard self.connection === link else { try? handle.close(); return }
                    self.originalTimer?.cancel()
                    if error == nil { next(remaining: remaining - Int64(chunk.count)) }
                    else {
                        try? handle.close()
                        self.disconnect(peer, message: "Original transfer was interrupted.")
                    }
                })
            } catch {
                try? handle.close()
                self.disconnect(peer, message: "Unable to finish reading the original.")
            }
        }
        next(remaining: size)
    }

    private func finishOriginal(_ peer: TrustedPeer, saved: Bool?) {
        guard let receipt = originalReceipt else { return }
        originalTimer?.cancel()
        originalReceipt = nil
        originalEarlyReceipt = nil
        originalBodyQueued = false
        exporting = false
        if saved == true {
            note(receipt.name, "Original saved on \(peer.name)", file: true, incoming: false, bytes: receipt.bytes)
        }
        DispatchQueue.main.async {
            guard self.fileSendPeer?.id == peer.id else { return }
            switch saved {
            case true?:
                self.status = "Saved \(receipt.name) on \(peer.name)."
                PhoneNotice.originalSent(receipt.name, to: self.computerName)
            case false?: self.status = "The PC could not save \(receipt.name)."
            case nil: self.status = "The PC has not confirmed saving \(receipt.name). Check the PC before retrying."
            }
        }
    }

    private func reportReceive(_ transfer: IncomingTransfer, received: Int, phase: ReceiveProgress.Phase) {
        if phase == .receiving || phase == .saving, transfer.bytes > 0 {
            let got = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
            let all = ByteCountFormatter.string(fromByteCount: Int64(transfer.bytes), countStyle: .file)
            BackgroundSend.receiving.update(fraction: Double(received) / Double(transfer.bytes),
                                            subtitle: phase == .saving ? "\(transfer.name) · Saving"
                                                                       : "\(transfer.name) · \(got) of \(all)")
        }
        let progress = ReceiveProgress(transferID: transfer.id, name: transfer.name, bytes: transfer.bytes,
                                       received: received, phase: phase)
        DispatchQueue.main.async {
            var named = progress
            named.from = self.computerName
            self.setReceiveProgress(named)
        }
    }

    private func beginPush(_ transfer: IncomingTransfer, chunked: Bool) {
        guard let peer = transportPeer else { return }
        let operation = UUID()
        let deadline = DispatchTime.now() + .seconds(120)
        incomingOperation = operation
        pushTransfer = transfer
        chunkedPush = chunked
        pushLeft = transfer.bytes
        reportReceive(transfer, received: 0, phase: .receiving)
        beginReceiveBackgroundTask(operation, peer: peer)
        reportIncomingPending(transfer, operation: operation, peer: peer, deadline: deadline)
        incomingQueue.async {
            let profile = SHA256.hash(data: Data(peer.credentialProfile.utf8)).map { String(format: "%02x", $0) }.joined()
            let state = Result { try self.incomingStore.prepare(transfer, profile: profile) }
            if case .success(.saved(let receipt?, at: let path)) = state {
                self.importReceivedReceipt(receipt, at: path)
            }
            // Continuing: what was kept goes into the checksum first, read once.
            var hasher = SHA256()
            if case .success(.staged(let staged)) = state, staged.offset > 0,
               let kept = try? FileHandle(forReadingFrom: staged.data) {
                var left = staged.offset
                while left > 0, let chunk = autoreleasepool(invoking: { try? kept.read(upToCount: min(left, 1 << 20)) }),
                      !chunk.isEmpty {
                    hasher.update(data: chunk)
                    left -= chunk.count
                }
                try? kept.close()
            }
            self.queue.async {
                guard self.transportPeer?.id == peer.id, self.incomingOperation == operation else {
                    if case .success(.staged(let staged)) = state { try? staged.handle.close() }
                    return
                }
                self.incomingHeartbeat?.cancel()
                switch state {
                case .failure:
                    self.rejectPush(transfer, peer: peer)
                case .success(.saved):
                    self.send("SAVED \(transfer.id)\n")
                    self.abortPush()
                    DispatchQueue.main.async { self.setReceiveProgress(nil) }
                case .success(.staged(let staged)):
                    self.pushStage = staged
                    self.pushHasher = hasher
                    self.pushLeft = transfer.bytes - staged.offset
                    self.pushChunkLeft = chunked ? 0 : self.pushLeft
                    self.reportReceive(transfer, received: staged.offset, phase: .receiving)
                    self.send("OFFSET \(transfer.id) \(staged.offset)\n")
                    DispatchQueue.main.async { self.showReceiveProgress(name: transfer.name) }
                    DispatchQueue.main.async {
                        if self.fileSendPeer?.id == peer.id { self.status = "Receiving \(transfer.name)" }
                    }
                    if self.pushLeft == 0 { self.finishPush() }
                    else { self.armFrameTimeout(peer: peer) }
                }
            }
        }
    }

    private func reportIncomingPending(_ transfer: IncomingTransfer, operation: UUID,
                                       peer: TrustedPeer, deadline: DispatchTime) {
        guard transportPeer?.id == peer.id, incomingOperation == operation else { return }
        guard DispatchTime.now() < deadline else {
            disconnect(peer, message: "The save folder is still processing the file. Check Files before retrying.")
            return
        }
        send("PENDING \(transfer.id)\n")
        let progress = DispatchWorkItem { [weak self] in
            self?.reportIncomingPending(transfer, operation: operation, peer: peer, deadline: deadline)
        }
        incomingHeartbeat = progress
        queue.asyncAfter(deadline: .now() + 4, execute: progress)
    }

    private static func digest(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: {
            guard let data = try file.read(upToCount: 1 << 20), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func writePushBody(peer: TrustedPeer) -> Bool {
        guard let stage = pushStage else { return false }
        let take = min(pushChunkLeft, buffer.count)
        guard take > 0 else { return true }
        if pushStopping {
            buffer.removeFirst(take)
            pushLeft -= take
            pushChunkLeft -= take
            return true
        }
        do {
            let piece = buffer.prefix(take)
            try stage.handle.write(contentsOf: piece)
            pushHasher?.update(data: piece)
            buffer.removeFirst(take)
            pushLeft -= take
            pushChunkLeft -= take
            let now = DispatchTime.now()
            if let transfer = pushTransfer, now.uptimeNanoseconds - lastReceiveProgressAt.uptimeNanoseconds >= 150_000_000 {
                lastReceiveProgressAt = now
                reportReceive(transfer, received: transfer.bytes - pushLeft, phase: .receiving)
            }
            return true
        } catch {
            disconnect(peer, message: "Unable to stage the incoming file. Check available storage and retry from the PC.")
            return false
        }
    }

    private func finishPush() {
        guard let stage = pushStage, let transfer = pushTransfer, let peer = transportPeer,
              let operation = incomingOperation else { return }
        if pushStopping {
            // A PC that didn't know STOP sent it all: don't save it.
            send("NO \(transfer.id)\n")
            abortPush(discard: true)
            return
        }
        do { try stage.handle.synchronize(); try stage.handle.close() }
        catch {
            rejectPush(transfer, peer: peer)
            return
        }
        pushStage = nil
        let streamed = pushHasher.map { $0.finalize().map { String(format: "%02x", $0) }.joined() }
        pushHasher = nil
        reportReceive(transfer, received: transfer.bytes, phase: .saving)
        // Saving a large file into its folder takes a while; the PC hears
        // PENDING every few seconds meanwhile.
        let saving = Int(TransferStaging.receiptWait(Int64(transfer.bytes)))
        reportIncomingPending(transfer, operation: operation, peer: peer, deadline: .now() + .seconds(max(120, saving)))
        incomingQueue.async {
            let result = Result {
                self.cancelledSavesLock.lock()
                let cancelled = self.cancelledSaves.remove(transfer.id) != nil
                self.cancelledSavesLock.unlock()
                if cancelled {
                    try? FileManager.default.removeItem(at: stage.data.deletingLastPathComponent())
                    throw CancellationError()
                }
                let saved: ReceivedFileStorage.SavedFile
                let receipt: IncomingTransferStore.Receipt
                if let intent = self.incomingStore.intent(for: stage),
                   let recovered = self.fileStorage.recover(intent, validates: { (try? Self.digest(of: $0)) == transfer.digest }) {
                    saved = recovered
                    receipt = try self.incomingStore.record(recovered.reference, from: peer.name, at: stage.receipt)
                    try? FileManager.default.removeItem(at: stage.data)
                } else {
                    let actual = try streamed ?? Self.digest(of: stage.data)
                    if actual != transfer.digest {
                        try FileManager.default.removeItem(at: stage.data)
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    var committed: IncomingTransferStore.Receipt?
                    saved = try self.fileStorage.save(stage.data, named: transfer.name,
                                                      planStage: self.incomingStore.planStaging,
                                                      clearStage: self.incomingStore.completeStaging, plan: { intent in
                        try self.incomingStore.plan(intent, at: stage)
                    }) { file in
                        committed = try self.incomingStore.record(file, from: peer.name, at: stage.receipt)
                    }
                    guard let committed else { throw CocoaError(.fileWriteUnknown) }
                    receipt = committed
                }
                self.importReceivedReceipt(receipt, at: stage.receipt)
                return saved
            }
            self.queue.async {
                let sameSession = self.transportPeer?.id == peer.id && self.incomingOperation == operation
                switch result {
                case .success(let saved):
                    // A cancel that came after it was saved is too late: it's kept.
                    self.cancelledSavesLock.lock()
                    self.cancelledSaves.remove(transfer.id)
                    self.cancelledSavesLock.unlock()
                    BackgroundSend.receiving.finish(success: true)
                    if sameSession {
                        self.send("SAVED \(transfer.id)\n")
                        self.abortPush()
                    }
                    DispatchQueue.main.async {
                        if self.receiveProgress?.transferID == transfer.id { self.setReceiveProgress(nil) }
                    }
                    self.announce(saved)
                case .failure(let error) where error is CancellationError:
                    // Cancelled while saving: nothing was kept.
                    if sameSession {
                        self.send("NO \(transfer.id)\n")
                        self.abortPush()
                    }
                case .failure:
                    if sameSession { self.rejectPush(transfer, peer: peer) }
                }
            }
        }
    }

    private func rejectPush(_ transfer: IncomingTransfer, peer: TrustedPeer) {
        send("NO \(transfer.id)\n")
        reportReceive(transfer, received: transfer.bytes - pushLeft, phase: .failed)
        abortPush()
        DispatchQueue.main.async {
            guard self.fileSendPeer?.id == peer.id else { return }
            self.status = "Unable to save \(transfer.name). Check available storage and try again."
        }
    }

    /// `discard` deletes what arrived (a cancel); otherwise it's kept for
    /// the PC to continue (a failure).
    private func abortPush(discard: Bool = false) {
        try? pushStage?.handle.close()
        if discard, let stage = pushStage {
            try? FileManager.default.removeItem(at: stage.data.deletingLastPathComponent())
        }
        pushStage = nil
        pushHasher = nil
        pushTransfer = nil
        pushLeft = 0
        pushChunkLeft = 0
        chunkedPush = false
        pushStopping = false
        BackgroundSend.receiving.finish(success: false)
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["porthole.receive.show"])
        }
        if let operation = incomingOperation {
            DispatchQueue.main.async { self.endReceiveBackgroundTask(operation) }
        }
        incomingOperation = nil
        incomingHeartbeat?.cancel()
        incomingHeartbeat = nil
    }

    private func beginReceiveBackgroundTask(_ operation: UUID, peer: TrustedPeer) {
        DispatchQueue.main.async {
            guard self.fileSendPeer?.id == peer.id, UIApplication.shared.applicationState != .background else { return }
            let task = UIApplication.shared.beginBackgroundTask(withName: "Finish receiving a file") { [weak self] in
                guard let self else { return }
                self.endReceiveBackgroundTask(operation)
                // While paired, Porthole keeps running in the background
                // (silent audio), so the transfer goes on; only stop it when
                // iOS is really about to suspend the app.
                if self.backgroundAudio?.requested == true { return }
                self.queue.async {
                    guard self.transportPeer?.id == peer.id, self.incomingOperation == operation else { return }
                    self.disconnect(peer, message: "iOS paused the transfer. Reopen Porthole to resume from the PC.")
                }
            }
            if task != .invalid { self.receiveBackgroundTasks[operation] = task }
        }
    }

    private func endReceiveBackgroundTask(_ operation: UUID) {
        if let task = receiveBackgroundTasks.removeValue(forKey: operation) {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private enum MediaKind { case photo, video, file }

    private static func mediaKind(_ name: String) -> MediaKind {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff":
            return .photo
        case "mov", "mp4", "m4v":
            return .video
        default:
            return .file
        }
    }

    /// Copies a received photo or video into Photos and leaves the file in the app.
    func saveToPhotos(_ url: URL, done: @escaping (Bool) -> Void) {
        let video = Self.mediaKind(url.lastPathComponent) == .video
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { done(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                if video {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }) { ok, _ in
                DispatchQueue.main.async { done(ok) }
            }
        }
    }

    static func isPhotoOrVideo(_ name: String) -> Bool {
        mediaKind(name) != .file
    }

    // The durable receipt owns the Activity identity. Replaying after a crash
    // is safe even if the Activity update committed just before termination.
    private func importReceivedReceipt(_ receipt: IncomingTransferStore.Receipt, at path: URL) {
        historyQueue.sync {
            do {
                if !historyLoaded {
                    historyRecords = try historyStore.load()
                    historyLoaded = true
                }
                let file = receipt.reference
                let record = ActivityItem(id: file.id, date: receipt.date, title: file.name,
                                          detail: "Received from \(receipt.device)", isFile: true, incoming: true,
                                          path: file.name, receivedFile: file, bytes: file.bytes, isUnread: true)
                historyRecords = try historyStore.importReceived(record, into: historyRecords)
                publishHistory()
                try incomingStore.markImported(path)
                historyStore.completeIncomingImport(file.id)
            } catch {
                reportHistory("A received file was saved. Porthole will retry adding it to Activity.")
            }
        }
    }

    private func announce(_ saved: ReceivedFileStorage.SavedFile) {
        let reference = saved.reference
        DispatchQueue.main.async {
            self.arrival = Arrival(name: reference.name, file: saved.localURL, reference: reference, warning: saved.warning)
            self.rememberReceivedFiles()
            self.status = saved.warning ?? "\(reference.name) received"
            if let warning = saved.warning { self.storageMessage = warning }
            PhoneNotice.fileArrived(reference)
            let arrivalID = self.arrival?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if self.arrival?.id == arrivalID { self.arrival = nil }
            }
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

    private func answerClipAsk(tries: Int, peerID: UUID, generation: Int) {
        guard foreground, clipboardLinkReady, clipboardPreference.allows(generation),
              fileSendPeer?.id == peerID else { return }
        if UIPasteboard.general.changeCount != seenCount {
            considerLocal(announceEmpty: false)
            return
        }
        if tries <= 0 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.answerClipAsk(tries: tries - 1, peerID: peerID, generation: generation)
        }
    }

    private func considerLocal(announceEmpty: Bool = true) {
        guard canSendClipboard(), foreground, !writingRemote,
              let peer = fileSendPeer, let generation = clipboardPreference.generation else { return }
        let board = UIPasteboard.general
        if board.hasImages, let type = board.types.first(where: { UTType($0)?.conforms(to: .image) == true }),
           let data = board.data(forPasteboardType: type), data.count <= 32 * 1024 * 1024 {
            seenCount = board.changeCount
            clipboardImageQueue.async {
                let png = CGImageSourceCreateWithData(data as CFData, nil).flatMap(Self.boundedClipboardPNG)
                DispatchQueue.main.async { self.deliverPreparedClipboardImage(png, peer: peer, generation: generation) }
            }
            return
        }
        if let text = board.string, !text.isEmpty { deliverText(text); return }
        if let url = board.url { deliverText(url.absoluteString); return }
        if board.hasStrings || board.hasImages || board.hasURLs {
            clipStatus = "Send clipboard to \(peer.name)."
            return
        }
        seenCount = board.changeCount
        if announceEmpty { clipStatus = "Clipboard is empty. Copy text, a link, or an image first." }
    }

    private func deliverText(_ text: String) {
        guard canSendClipboard() else { return }
        seenCount = UIPasteboard.general.changeCount
        guard !text.isEmpty else { return }
        guard text.utf8.count <= 256 * 1024 else { clipStatus = "Clipboard text exceeds the 256 KB limit."; return }
        if isPairingText(text) { clipStatus = "Pairing details stay on this iPhone."; return }
        queueClip(kind: "T", data: Data(text.utf8))
        clipStatus = "Clipboard queued for \(computerName)."
    }

    private func deliverPreparedClipboardImage(_ data: Data?, peer: TrustedPeer, generation: Int) {
        guard foreground, fileSendPeer?.id == peer.id, clipboardPreference.allows(generation) else { return }
        guard let data else { clipStatus = "Unable to prepare this clipboard image within the transfer limits."; return }
        seenCount = UIPasteboard.general.changeCount
        queueClip(kind: "P", data: data)
        clipStatus = "Image queued for \(peer.name)."
    }

    private func isPairingText(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.range(of: "porthole://", options: .caseInsensitive) != nil { return true }
        let fields = raw.split(whereSeparator: \.isWhitespace)
        if fields.count == 2, fields[1].utf8.count == 8, fields[1].allSatisfy(\.isHexDigit),
           TrustedPeer.pairingHost(String(fields[0])) != nil { return true }
        guard fields.count == 1, let peer = fileSendPeer else { return false }
        return PairingCredential.load("bootstrap/" + peer.credentialProfile)?.caseInsensitiveCompare(raw) == .orderedSame
    }

    private func queueClip(kind: Character, data: Data) {
        guard let generation = clipboardPreference.generation, let peer = fileSendPeer else { return }
        queue.async {
            guard self.transportPeer?.id == peer.id, self.clipboardPreference.allows(generation) else { return }
            self.pendingKind = kind
            self.pendingData = data
            self.pendingClipboardGeneration = generation
            self.flushClip()
        }
    }

    private func flushClip() {
        // Clipboard packets may not interrupt an original file body.
        guard let generation = pendingClipboardGeneration,
              clipboardPreference.allows(generation) else {
            pendingData = nil
            pendingClipboardGeneration = nil
            return
        }
        guard acceptedClipboardGeneration == generation, syncReady, !sendingOriginal, let data = pendingData, let link = connection, let peer = transportPeer else { return }
        pendingData = nil
        pendingClipboardGeneration = nil
        let kind = pendingKind
        var packet = Data("CLIP \(kind) \(data.count)\n".utf8)
        packet.append(data)
        clipboardPreference.performIfAllowed(generation) {
            link.send(content: packet, completion: .contentProcessed { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.fileSendPeer?.id == peer.id, self.clipboardPreference.allows(generation) else { return }
                    guard error == nil else {
                        self.clipStatus = "Clipboard transfer failed. Try again."
                        return
                    }
                    self.clipStatus = "Clipboard sent to \(self.computerName)."
                    let title = kind == "P" ? "Image" : Self.preview(String(data: data, encoding: .utf8) ?? "Text")
                    self.note(title, "Sent to the PC", file: false, incoming: false,
                              clipboardText: kind == "T" ? String(data: data, encoding: .utf8) : nil,
                              clipboardImage: kind == "P" ? data : nil)
                }
            })
        }
    }

    private func applyRemote(kind: Character, data: Data, generation: Int?, peer: TrustedPeer) {
        guard let generation, clipboardPreference.allows(generation) else { return }
        let now = DispatchTime.now()
        if let lastRemoteClipboardAt, now < lastRemoteClipboardAt + .milliseconds(100) { return }
        lastRemoteClipboardAt = now
        if kind == "T", let text = String(data: data, encoding: .utf8), !text.isEmpty {
            DispatchQueue.main.async {
                guard self.foreground, self.fileSendPeer?.id == peer.id, self.clipboardPreference.allows(generation) else { return }
                self.writeLocalClipboard(type: .utf8PlainText, value: text)
                self.clipStatus = "Clipboard received from \(peer.name)."
                self.note(Self.preview(text), "Received from \(peer.name)", file: false, incoming: true, clipboardText: text)
            }
        } else if kind == "P", !decodingRemoteClipboard {
            decodingRemoteClipboard = true
            clipboardImageQueue.async {
                let png = CGImageSourceCreateWithData(data as CFData, nil).flatMap(Self.boundedClipboardPNG)
                self.queue.async { self.decodingRemoteClipboard = false }
                DispatchQueue.main.async {
                    guard self.foreground, self.fileSendPeer?.id == peer.id,
                          self.clipboardPreference.allows(generation), let png else { return }
                    self.writeLocalClipboard(type: .png, value: png)
                    self.clipStatus = "Image received from \(peer.name)."
                    self.note("Image", "Received from \(peer.name)", file: false, incoming: true, clipboardImage: png)
                }
            }
        }
    }

    private func writeLocalClipboard(type: UTType, value: Any) {
        let board = UIPasteboard.general
        writingRemote = true
        board.setItems([[type.identifier: value]], options: [.localOnly: true])
        seenCount = board.changeCount
        writingRemote = false
    }

    private static func boundedClipboardPNG(_ source: CGImageSource) -> Data? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 24_000_000 else { return nil }
        for side in [2048, 1440, 1024] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination), data.length <= 8 * 1024 * 1024 { return data as Data }
        }
        return nil
    }

    private func loadSaved() {
        guard requestedPeer == nil else { return }
        if let pending = PendingPairing.load() {
            requestedPeer = pending.peer
            address = pending.peer.host
            // Use the current code first; PAIR SAVED recovers a lost PAIRED acknowledgement.
            reconnectAttempt = pending.activeCode != nil ? 0 : 1
        } else if let saved = savedPeer() {
            requestedPeer = saved
            address = saved.host
        }
    }

    private func scheduleReconnect() {
        guard (foreground || backgroundAudio?.requested == true), !disconnectedByPC,
              let peer = requestedPeer else { return }
        reconnectWork?.cancel()
        if reconnectAttempt >= 4, PendingPairing.load()?.peer.samePairing(as: peer) == true {
            status = "Pairing could not finish. Tap Connect to retry, or use the current code shown on your PC."
            return
        }
        let delay = min(2 << min(reconnectAttempt, 3), 15)
        reconnectAttempt += 1
        if reconnectAttempt <= 3 || reconnectAttempt % 20 == 0 {
            DiagnosticLog.note("reconnect: try \(reconnectAttempt) in \(delay) s (\(foreground ? "open" : "in the background, silent audio \(backgroundAudio?.requested == true ? "on" : "off")"))")
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.requestedPeer?.id == peer.id else { return }
            self.reconnectWork = nil
            guard (self.foreground || self.backgroundAudio?.requested == true), !self.disconnectedByPC,
                  !self.linked, !self.connecting else { return }
            self.connectCurrentPeer()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
    }
}
