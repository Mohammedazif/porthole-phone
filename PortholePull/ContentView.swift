import Accessibility
import AVFoundation
import ImageIO
import Photos
import PhotosUI
import QuickLook
import ReplayKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 88, height: 52))
        // The broadcast extension uses the containing app's bundle identifier plus this suffix.
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "local.porthole.pull") + ".broadcast"
        picker.showsMicrophoneButton = false
        picker.overrideUserInterfaceStyle = .dark
        picker.tintColor = .white
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) { }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var index = PhotoIndex()
    @StateObject private var client = PullClient()
    @StateObject private var input = InputDeviceMonitor()
    @StateObject private var fileSender = OutboundFileSender()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PhoneAppearance.preferenceKey) private var appearance: PhoneAppearance = .system
    @State private var activeSheet: PhoneSheet?
    @State private var lastSheet: PhoneSheet?
    @State private var offeredChoiceIDs: [String]?
    @State private var confirmedPhotoChoice = false
    @State private var pendingFiles: [ReceivedFileReference] = []
    @State private var openingFile: ReceivedFileReference?
    @State private var pendingSend: SendSelection?
    @State private var sendBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @State private var pendingWidgetDestination: WidgetOpenRequest?
    @State private var pendingWidgetShortcut: WidgetOpenRequest?
    @State private var connectionJump: ConnectionJump?
    @State private var manualDraft = PairingDraft()
    @State private var manualError: String?
    @State private var manualAfterScan = false
    @State private var scanError: String?
    @State private var cameraUnavailable = false
    @State private var captured = false
    @State private var hideSharing = false
    @State private var shareStarted: Date?
    @State private var broadcastStopRequestedAt: Date?
    @State private var confirmingStopBroadcast = false
    @State private var activityFilter = 0
    @State private var selectingHistory = false
    @State private var selectedHistory = Set<UUID>()
    @State private var confirmingClearHistory = false
    @State private var copiedItemID: UUID?
    @State private var actionError: String?
    @State private var selectedTab = 0
    @State private var sendAudioToPC = TrustedPeerStore.broadcastAudioEnabled()

    private var visibleUnreadRecordIDs: Set<UUID> {
        guard selectedTab == 1, activityFilter == 0, scenePhase == .active,
              activeSheet == nil, lastSheet == nil, openingFile == nil, pendingFiles.isEmpty,
              actionError == nil, !confirmingClearHistory else { return [] }
        return Set(client.history.lazy.filter(\.isUnreadReceivedFile).map(\.id))
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                Group {
                    if isPortholeBroadcasting && !hideSharing {
                        sharingScreen
                    } else if client.linked {
                        connected
                    } else {
                        findPC
                    }
                }
                .background(phoneBackground)
            }
            .tabItem {
                Label {
                    Text("Connect")
                } icon: {
                    Image("PortholeLogo").renderingMode(.original)
                }
            }
            .tag(0)

            NavigationStack { activity }
                .tabItem { Label("Activity", systemImage: "clock") }
                .badge(client.unreadReceived)
                .tag(1)

            NavigationStack { settings }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .tint(.primary)
        .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.14, green: 0.58, blue: 0.32)))
    }

    private var activeTabs: some View {
        let visibleRecords = visibleUnreadRecordIDs
        return tabs
        .task(id: visibleRecords) { @MainActor in
            guard !visibleRecords.isEmpty else { return }
            // A notification response can arrive just after the scene becomes active.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled, visibleRecords == visibleUnreadRecordIDs else { return }
            client.markReceivedRecordsRead(visibleRecords)
        }
        .onChange(of: client.arrival) { _, arrival in
            if let arrival, scenePhase == .active {
                UIAccessibility.post(notification: .announcement, argument: "\(arrival.name) received")
            }
        }
        .onAppear {
            client.bind(index: index)
            client.cameForward()
            fileSender.refreshPending(for: client.fileSendPeer)
            index.refreshAuthorization()
            updateCapture()
            refreshBroadcast()
            openPendingNotice()
            presentNextSheet()
        }
        .onOpenURL { url in
            guard let destination = WidgetDestination(url: url) else { return }
            pendingWidgetShortcut = nil
            let peer = (destination == .share || destination == .send) ? client.widgetShortcutPairing : nil
            pendingWidgetDestination = WidgetOpenRequest(destination: destination, peer: peer)
            presentNextSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            updateCapture()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                client.cameForward()
                fileSender.refreshPending(for: client.fileSendPeer)
                index.refreshAuthorization()
                input.refresh()
                updateCapture()
                refreshBroadcast()
                presentNextSheet()
            }
            if phase == .background { client.enteredBackground() }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if scenePhase != .background {
                refreshBroadcast()
                if pendingWidgetShortcut != nil { presentNextSheet() }
            }
        }
    }

    private var workflowTabs: some View {
        activeTabs
        .background {
            BluetoothAutoVerification(client: client, available: activeSheet == nil && lastSheet == nil && actionError == nil)
        }
        .sheet(item: $activeSheet, onDismiss: sheetDidDismiss) { sheet in
            sheetContent(sheet)
        }
        .onChange(of: fileSender.phase) { _, phase in
            if phase == .sending {
                guard sendBackgroundTask == .invalid else { return }
                sendBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish sending files") {
                    fileSender.cancel()
                    endSendBackgroundTask()
                }
            } else {
                endSendBackgroundTask()
            }
        }
        .onChange(of: client.fileSendPeer) { _, peer in
            fileSender.refreshPending(for: peer)
            if pendingWidgetShortcut != nil { presentNextSheet() }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab != 0 { pendingWidgetShortcut = nil }
        }
        .onChange(of: client.choiceIDs) { _, choices in
            if choices.isEmpty { offeredChoiceIDs = nil }
            if case .photoChoice(_, let ids) = activeSheet, choices != ids { activeSheet = nil }
            presentNextSheet()
        }
        .onChange(of: actionError) { _, error in
            if error == nil { presentNextSheet() }
        }
        .onChange(of: confirmingClearHistory) { _, confirming in
            if !confirming { presentNextSheet() }
        }
    }

    var body: some View {
        workflowTabs
        .confirmationDialog(activityFilter == 2 ? "Clear clipboard history?" : "Clear transfer history for this view?", isPresented: $confirmingClearHistory, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { client.removeActivity(Set(filteredHistory.map(\.id))); selectedHistory.removeAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(activityFilter == 2
                 ? "This removes saved clipboard items from Porthole on this iPhone."
                 : "This removes activity records. You can still find received files in their saved folders.")
        }
        .alert("Stop screen sharing?", isPresented: $confirmingStopBroadcast) {
            Button("Stop sharing", role: .destructive, action: stopBroadcast)
            Button("Cancel", role: .cancel) { }
        }
        .alert("Porthole", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .overlay {
            if openingFile != nil {
                ProgressView("Opening file…")
                    .padding(24)
                    .glassPanel(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .portholeOpenReceived)) { _ in
            openPendingNotice()
        }
        .safeAreaInset(edge: .top) {
            if let arrival = client.arrival {
                arrivalBanner(arrival)
            }
        }
    }

    private func endSendBackgroundTask() {
        guard sendBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(sendBackgroundTask)
        sendBackgroundTask = .invalid
    }

    @ViewBuilder
    private func sheetContent(_ sheet: PhoneSheet) -> some View {
        switch sheet {
        case .manualPairing:
            if pairingScreenIsCaptured { pairingBlockedSheet } else { manualEntry }
        case .feature(let feature):
            NavigationStack {
                ConnectionSettings(feature: feature, client: client, index: index, input: input, verifiesBluetooth: feature == .input)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { activeSheet = nil } }
                    }
            }
            .presentationDetents([.large])
        case .sendPicker(let peer):
            SendFilePicker { urls in
                if !urls.isEmpty { pendingSend = SendSelection(urls: urls, peer: peer) }
                activeSheet = nil
            }
        case .sendReview(let peer):
            SendFilesSheet(sender: fileSender, client: client, peer: peer)
        case .qrScanner:
            if pairingScreenIsCaptured { pairingBlockedSheet } else { scanSheet }
        case .photoChoice(let peer, let ids):
            choiceSheet(peer: peer, ids: ids)
        case .received(let item):
            ReceivedFileSheet(item: item, client: client)
        case .saveFolder:
            SaveFolderPicker { url in
                if let url { client.chooseSaveFolder(url) }
                activeSheet = nil
            }
        case .clipboard(let item):
            ClipboardHistorySheet(item: item, client: client)
        }
    }

    private func showSheet(_ sheet: PhoneSheet) {
        guard activeSheet == nil, lastSheet == nil, openingFile == nil, actionError == nil else { return }
        lastSheet = sheet
        activeSheet = sheet
    }

    private func sheetDidDismiss() {
        let previous = lastSheet
        lastSheet = nil
        if case .sendReview = previous {
            fileSender.reset()
            fileSender.refreshPending(for: client.fileSendPeer)
        }
        if case .photoChoice(let peer, let ids) = previous {
            if !confirmedPhotoChoice, client.fileSendPeer?.id == peer.id, client.choiceIDs == ids {
                client.pickChoice(nil)
            }
            confirmedPhotoChoice = false
        }
        presentNextSheet()
    }

    private func presentNextSheet() {
        guard scenePhase == .active, activeSheet == nil, lastSheet == nil,
              openingFile == nil, actionError == nil, !confirmingClearHistory else { return }
        if manualAfterScan {
            manualAfterScan = false
            prepareManualEntry(host: client.address)
            return
        }
        if let selection = pendingSend {
            pendingSend = nil
            guard client.matchesReviewedPairing(selection.peer) else {
                actionError = "The connected PC changed before the transfer. Select your files again after reconnecting."
                return
            }
            fileSender.prepare(selection.urls, for: selection.peer)
            showSheet(.sendReview(selection.peer))
            return
        }
        if let peer = client.fileSendPeer, !client.choiceIDs.isEmpty, offeredChoiceIDs != client.choiceIDs {
            let ids = client.choiceIDs
            offeredChoiceIDs = ids
            showSheet(.photoChoice(peer, ids))
            return
        }
        if !pendingFiles.isEmpty {
            let reference = pendingFiles.removeFirst()
            openingFile = reference
            client.openReceived(reference) { result in
                openingFile = nil
                switch result {
                case .success(let url):
                    client.markReceivedRead(reference.id)
                    if client.arrival?.reference?.id == reference.id { client.clearArrival() }
                    showSheet(.received(ReceivedFile(url: url, name: reference.name, folderName: reference.folderName,
                                                     referenceID: reference.id, release: client.releaseReceivedPreview)))
                case .failure(let error): actionError = error.localizedDescription
                }
            }
            return
        }
        if let request = pendingWidgetDestination {
            pendingWidgetDestination = nil
            openWidgetDestination(request)
        } else {
            resumeWidgetShortcut()
        }
    }

    private func openWidgetDestination(_ request: WidgetOpenRequest) {
        let destination = request.destination
        switch destination {
        case .received, .clipboard:
            selectingHistory = false
            selectedHistory.removeAll()
            activityFilter = destination == .received ? 0 : 2
            selectedTab = 1
        case .connect:
            selectedTab = 0
            hideSharing = true
            connectionJump = ConnectionJump(target: .connect)
        case .share, .send:
            selectedTab = 0
            if let peer = request.peer, client.fileSendPeer?.samePairing(as: peer) == true {
                openConnectedShortcut(destination)
            } else {
                hideSharing = true
                connectionJump = ConnectionJump(target: .connect)
                if let peer = request.peer, client.reconnectForWidgetShortcut(peer) {
                    pendingWidgetShortcut = WidgetOpenRequest(destination: destination, peer: peer,
                        reconnectDeadline: ContinuousClock.now.advanced(by: .seconds(15)))
                }
            }
        case .transfer:
            selectedTab = 0
            hideSharing = true
            connectionJump = ConnectionJump(target: .transfer)
        }
    }

    private struct WidgetOpenRequest {
        let destination: WidgetDestination
        let peer: TrustedPeer?
        var reconnectDeadline: ContinuousClock.Instant?
    }

    private func resumeWidgetShortcut() {
        guard let shortcut = pendingWidgetShortcut else { return }
        guard let peer = shortcut.peer, let deadline = shortcut.reconnectDeadline,
              ContinuousClock.now < deadline, client.matchesReviewedPairing(peer) else {
            pendingWidgetShortcut = nil
            return
        }
        guard client.fileSendPeer?.samePairing(as: peer) == true else { return }
        pendingWidgetShortcut = nil
        openConnectedShortcut(shortcut.destination)
    }

    private func openConnectedShortcut(_ destination: WidgetDestination) {
        if destination == .send {
            openSendPicker()
        } else {
            hideSharing = false
            connectionJump = ConnectionJump(target: .share)
        }
    }

    private struct ConnectionJump: Equatable {
        enum Target: Hashable { case connect, share, transfer }
        let target: Target
        private let id = UUID()
    }

    private func scrollConnection(_ proxy: ScrollViewProxy, jump: ConnectionJump?, canShare: Bool) {
        guard let jump else { return }
        let target = jump.target == .share && !canShare ? .connect : jump.target
        proxy.scrollTo(target, anchor: .top)
    }

    private func openPendingNotice() {
        for reference in NoticeDelegate.takePendingFiles() { openReceived(reference) }
    }

    private func openReceived(_ reference: ReceivedFileReference) {
        guard openingFile?.id != reference.id, !pendingFiles.contains(where: { $0.id == reference.id }) else { return }
        if case .received(let item) = activeSheet, item.referenceID == reference.id { return }
        pendingFiles.append(reference)
        presentNextSheet()
    }

    private func openArrival() {
        guard let reference = client.arrival?.reference else { return }
        openReceived(reference)
    }

    private func prepareManualEntry(host: String = "") {
        guard canOpenPairing() else { return }
        manualDraft = PairingDraft(address: host)
        manualError = nil
        showSheet(.manualPairing)
    }

    private func openScanner() {
        guard canOpenPairing() else { return }
        scanError = nil
        cameraUnavailable = false
        showSheet(.qrScanner)
    }

    private var pairingScreenIsCaptured: Bool {
        captured || UIScreen.main.isCaptured || (isPortholeBroadcasting && !deliveryStopped)
    }

    private let pairingCaptureMessage = "Stop screen sharing or recording before opening pairing details."

    private func canOpenPairing() -> Bool {
        guard !pairingScreenIsCaptured else {
            actionError = pairingCaptureMessage
            return false
        }
        return true
    }

    private var pairingBlockedSheet: some View {
        NavigationStack {
            ContentUnavailableView("Pairing paused", systemImage: "lock.shield", description: Text(pairingCaptureMessage))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { activeSheet = nil } }
                }
        }
    }

    private func openSendPicker() {
        guard let peer = client.fileSendPeer else { return }
        showSheet(.sendPicker(peer))
    }

    private var phoneBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark ? [Color(white: 0.075), .black, Color(white: 0.065)]
                : [.white, Color(uiColor: .systemGroupedBackground), Color(uiColor: .secondarySystemGroupedBackground)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var findPC: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 13) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 28, weight: .medium))
                            .frame(width: 72, height: 72)
                            .background(cardFill, in: RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                            .padding(.bottom, 8)
                        Text("Connect to your PC").font(.largeTitle.bold())
                        Text("Open Porthole on your PC. Connect both devices to the same local network.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .id(ConnectionJump.Target.connect)

                    if let saved = client.savedPC { savedPCRow(saved) }
                    receiveStatus.id(ConnectionJump.Target.transfer)
                    VStack(spacing: 12) {
                        GlassCapsuleButton(title: "Scan QR code", systemImage: "qrcode.viewfinder",
                                           prominent: true) { openScanner() }
                        GlassCapsuleButton(title: "Connect manually") { prepareManualEntry(host: client.address) }
                    }
                    if !client.status.isEmpty {
                        Text(client.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: connectionJump, initial: true) { _, jump in
                scrollConnection(proxy, jump: jump, canShare: false)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func savedPCRow(_ saved: TrustedPeer) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Saved PC")
                .font(.caption.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            pcRow(TrustedPeer.computerName(saved.name) ?? saved.host, detail: saved.host) {
                client.connectSavedPC()
            }
            .background(cardFill, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private func pcRow(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: "desktopcomputer").frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("Connect").font(.footnote).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var deviceTitle: String {
        client.computerName
    }

    private var connected: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 650
            let stageHeight = min(340, max(180, geometry.size.height - (compact ? 324 : 340)))
            ScrollViewReader { proxy in
                ViewThatFits(in: .vertical) {
                    connectedContent(stageHeight: stageHeight, compact: compact)
                    connectedContent(stageHeight: max(162, stageHeight - 44), compact: true)
                    ScrollView { connectedContent(stageHeight: stageHeight, compact: compact) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .onChange(of: connectionJump, initial: true) { _, jump in
                    scrollConnection(proxy, jump: jump, canShare: true)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func connectedContent(stageHeight: CGFloat, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Connected", systemImage: "circle.fill")
                        .labelStyle(ConnectionStatusLabel())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.green : Color(red: 0.09, green: 0.50, blue: 0.24))
                    Text(deviceTitle).font(.title.bold()).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                Spacer()
                GlassIconButton(systemImage: "arrow.up.arrow.down", label: "Switch PC") {
                    prepareManualEntry(host: client.address)
                }
            }
            .id(ConnectionJump.Target.connect)

            if client.receiveProgress != nil || client.widgetReceiveAttention != nil {
                receiveStatus.id(ConnectionJump.Target.transfer)
            }
            if fileSender.pendingCount > 0, let peer = client.fileSendPeer {
                linkRow("Pending file transfer", "\(fileSender.pendingCount) ready to retry", icon: "arrow.clockwise", last: true) {
                    fileSender.restorePending(for: peer)
                    showSheet(.sendReview(peer))
                }
                .background(cardFill, in: RoundedRectangle(cornerRadius: 18))
            }
            shareStage(height: stageHeight).id(ConnectionJump.Target.share)

            VStack(spacing: 0) {
                linkRow("Mouse and keyboard", client.inputControlSummary, icon: "computermouse") {
                    showSheet(.feature(.input))
                }
                linkRow("Photo access", index.accessLabel, icon: "photo") { showSheet(.feature(.photos)) }
                linkRow("Clipboard sync", client.clipboardSummary, icon: "clipboard", last: true) {
                    showSheet(.feature(.clipboard))
                }
            }
            .background(cardFill, in: RoundedRectangle(cornerRadius: 22))

            let actions = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            actions {
                actionCard("Send files", systemImage: "doc") { openSendPicker() }
                ClipboardSendButton(client: client)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 10 : 13)
    }

    private struct ConnectionStatusLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) {
                configuration.icon.font(.system(size: 6)).accessibilityHidden(true)
                configuration.title
            }
        }
    }

    @ViewBuilder
    private var receiveStatus: some View {
        if let receive = client.receiveProgress {
            VStack(alignment: .leading, spacing: 8) {
                Text(receive.name).font(.headline)
                Text(receive.message).font(.subheadline).foregroundStyle(.secondary)
                if receive.phase == .receiving {
                    ProgressView(value: Double(receive.received), total: Double(receive.bytes)) {
                        Text("File transfer progress").accessibilityHidden(true)
                    } currentValueLabel: {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(receive.received), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(receive.bytes), countStyle: .file))")
                    }
                    .accessibilityLabel("Receiving \(receive.name)")
                } else if receive.phase == .saving {
                    ProgressView("Saving file")
                } else {
                    Button("Dismiss") { client.dismissReceiveStatus() }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 18))
        } else if let phase = client.widgetReceiveAttention {
            VStack(alignment: .leading, spacing: 8) {
                Text(phase == .failed ? "File could not be saved" : "Transfer interrupted").font(.headline)
                Text(phase == .failed
                     ? "Check space or choose another save folder, then retry from the PC."
                     : "Retry from your PC to resume the transfer.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Dismiss") { client.dismissReceiveStatus() }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var cardFill: Color {
        Color(.secondarySystemGroupedBackground)
    }

    private var isPortholeBroadcasting: Bool {
        switch client.broadcastStatus?.phase {
        case .connecting, .live, .waitingForFrames, .reconnecting, .deliveryStopped: true
        default: false
        }
    }

    private var deliveryStopped: Bool { client.broadcastStatus?.phase == .deliveryStopped }

    private var isLive: Bool { client.broadcastStatus?.phase == .live }

    private var stoppingBroadcast: Bool { broadcastStopRequestedAt != nil }

    private func refreshBroadcast() {
        let wasBroadcasting = isPortholeBroadcasting
        client.refreshBroadcastStatus()
        if isLive, shareStarted == nil { shareStarted = Date() }
        if isPortholeBroadcasting, !wasBroadcasting { hideSharing = false }
        if !isPortholeBroadcasting || deliveryStopped {
            shareStarted = nil
            broadcastStopRequestedAt = nil
        } else if let requestedAt = broadcastStopRequestedAt, Date().timeIntervalSince(requestedAt) >= 5 {
            broadcastStopRequestedAt = nil
            actionError = "Open Control Center, then tap the active Screen Recording control to stop the broadcast."
        }
    }

    private func updateCapture() {
        // AirPlay and local recording also use the system capture indicator.
        captured = UIScreen.main.isCaptured
        if captured {
            manualDraft.code = ""
            manualAfterScan = false
        }
        refreshBroadcast()
    }

    private func stopBroadcast() {
        if client.requestBroadcastStop() { broadcastStopRequestedAt = Date() }
        else { actionError = "Open Control Center, then tap the active Screen Recording control to stop the broadcast." }
    }

    private func shareStage(height: CGFloat) -> some View {
        let available = client.canStartBroadcast && !captured
        let diameter = min(218, max(122, height - 82))
        return VStack(spacing: 10) {
            PortholeLens(diameter: diameter) {
                if isPortholeBroadcasting || !available {
                    Button {
                        if isPortholeBroadcasting { hideSharing = false }
                        else { actionError = client.sharedPairingIssue ?? broadcastHelp }
                    } label: {
                        shareLensLabel(active: isPortholeBroadcasting)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(isPortholeBroadcasting ? "" : broadcastHelp)
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 29, weight: .medium))
                            .frame(width: 88, height: 52)
                            .accessibilityHidden(true)
                            .overlay {
                                BroadcastPicker()
                                    .opacity(0.02)
                                    .accessibilityLabel("Share screen")
                            }
                        Text("Share screen").font(.subheadline.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            Text(broadcastHelp)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: height)
        .background {
            RoundedRectangle(cornerRadius: 28)
                .fill(LinearGradient(
                    colors: [Color(white: 0.225), Color(white: 0.085)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.14)) }
        }
    }

    private func shareLensLabel(active: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: active ? "rectangle.on.rectangle" : "arrow.up.square")
                .font(.title3.weight(.medium))
                .accessibilityHidden(true)
            Text(active ? "Show broadcast" : "Share screen").font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    private var broadcastHelp: String {
        if deliveryStopped { return "Finish in Control Center." }
        if isPortholeBroadcasting { return "View or stop screen sharing." }
        if let status = client.broadcastStatus, status.phase == .failed, let message = status.message { return message }
        if client.sharedPairingIssue != nil { return "Screen sharing unavailable in this install." }
        if captured { return "Stop the current recording in Control Center first." }
        if !client.canStartBroadcast { return "Connect to your PC first." }
        return "Select Start Broadcast."
    }

    private var broadcastLabel: String {
        if stoppingBroadcast { return "Stopping" }
        switch client.broadcastStatus?.phase {
        case .live: return "Live"
        case .waitingForFrames: return "Waiting for frames"
        case .reconnecting: return "Reconnecting"
        case .deliveryStopped: return "Delivery stopped"
        default: return "Connecting"
        }
    }

    private var sharingScreen: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack {
                    GlassIconButton(systemImage: "chevron.left", label: "Back") { hideSharing = true }
                    Spacer()
                    Label(broadcastLabel, systemImage: isLive && !stoppingBroadcast ? "dot.radiowaves.left.and.right" : "clock")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                VStack(spacing: 4) {
                    Text(isLive ? "Sharing to" : "Connecting to")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(deviceTitle)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                }
                if isLive, let started = shareStarted {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(started)))
                        PortholeLens(diameter: dynamicTypeSize.isAccessibilitySize ? 200 : 248) {
                            VStack(spacing: 4) {
                                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                                    .font(.title.monospacedDigit())
                                Text("Elapsed time")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    ProgressView(broadcastLabel)
                        .frame(minHeight: 70)
                }
                let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    statCard("Video", "Up to 24 fps")
                    statCard("Audio", client.fileSendPeer?.broadcastVersion == 2 ? "On PC" : "On iPhone")
                    statCard("Input", input.mouseConnected && input.keyboardConnected ? "Detected" : "Setup required")
                }
                receiveStatus
                Text(client.broadcastStatus?.message ?? "Your screen and notifications stay visible until you stop sharing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            Button(role: .destructive, action: {
                if deliveryStopped {
                    actionError = "Open Control Center, then tap the active Screen Recording control to finish the broadcast."
                } else {
                    confirmingStopBroadcast = true
                }
            }) {
                Text(deliveryStopped ? "End in Control Center" : stoppingBroadcast ? "Stopping…" : "Stop sharing")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(stoppingBroadcast)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func linkRow(_ title: String, _ detail: String, icon: String, last: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: icon).frame(width: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
                if !last { Divider().padding(.leading, 52) }
            }
        }
        .buttonStyle(.plain)
    }

    private func actionCard(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        GlassCapsuleButton(title: title, systemImage: systemImage, compact: true, action: action)
    }

    private var filteredHistory: [PullClient.ActivityItem] {
        client.history.filter { item in
            switch activityFilter {
            case 0: return item.isFile && item.incoming
            case 1: return item.isFile && !item.incoming
            default: return !item.isFile
            }
        }
    }

    private var emptyHistoryMessage: String {
        switch activityFilter {
        case 0: "No received files yet."
        case 1: "No sent files yet."
        default: client.clipboardHistoryEnabled ? "No clipboard activity yet." : "Clipboard history is off."
        }
    }

    @ViewBuilder
    private var activityPicker: some View {
        let picker = Picker("Show", selection: $activityFilter) {
            Text("Received").tag(0)
            Text("Sent").tag(1)
            Text("Clipboard").tag(2)
        }
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }
    }

    private func activitySelection(_ items: [ActivityRecord]) -> some View {
        Section {
            HStack {
                Button("Select all") { selectedHistory = Set(items.map(\.id)) }
                    .disabled(items.isEmpty || selectedHistory.count == items.count)
                Spacer()
                Button("Delete (\(selectedHistory.count))", role: .destructive) {
                    client.removeActivity(selectedHistory)
                    selectedHistory.removeAll()
                    selectingHistory = false
                }
                .foregroundStyle(.red)
                .disabled(selectedHistory.isEmpty)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func historyRow(_ item: ActivityRecord) -> some View {
        if selectingHistory {
            let isSelected = selectedHistory.contains(item.id)
            Button {
                if !selectedHistory.insert(item.id).inserted { selectedHistory.remove(item.id) }
            } label: {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .accessibilityHidden(true)
                    ActivityRow(item: item, canOpen: false)
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else if let reference = item.fileReference {
            Button { openReceived(reference) } label: {
                ActivityRow(item: item, canOpen: true)
            }
            .buttonStyle(.plain)
        } else if !item.isFile {
            HStack(spacing: 8) {
                Button { showSheet(.clipboard(item)) } label: {
                    ActivityRow(item: item, file: client.clipboardPreviewURL(item), canOpen: false)
                }
                .buttonStyle(.plain)
                if client.canCopy(item) { clipboardCopyButton(for: item) }
            }
        } else {
            ActivityRow(item: item, canOpen: false)
        }
    }

    private func recentActivity(_ items: [ActivityRecord]) -> some View {
        Section {
            if items.isEmpty {
                Text(emptyHistoryMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in historyRow(item) }
                .onDelete { offsets in
                    client.removeActivity(Set(offsets.map { items[$0].id }))
                }
        } header: {
            HStack {
                Text("Recent")
                Spacer()
                if !items.isEmpty {
                    Button("Clear history") { confirmingClearHistory = true }
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        }
    }

    private var activity: some View {
        let items = filteredHistory
        return List {
            activityPicker
            if selectingHistory { activitySelection(items) }
            recentActivity(items)
            if activityFilter == 2, !selectingHistory {
                Section {
                    ClipboardActions(client: client)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if !client.activityMessage.isEmpty {
                Section { Text(client.activityMessage).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(phoneBackground)
        .navigationTitle("Activity")
        .onChange(of: activityFilter) { _, _ in selectedHistory.removeAll(); selectingHistory = false }
        .onChange(of: client.clipboardHistoryEnabled) { _, enabled in
            if !enabled, activityFilter == 2 {
                selectedHistory.removeAll()
                selectingHistory = false
            }
        }
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectingHistory ? "Cancel" : "Select") {
                        selectingHistory.toggle(); selectedHistory.removeAll()
                    }
                }
            }

        }
    }

    private func clipboardCopyButton(for item: ActivityRecord) -> some View {
        let copied = copiedItemID == item.id
        return Button {
            client.copyActivity(item) { success in
                if success {
                    copiedItemID = item.id
                    client.activityMessage = ""
                    AccessibilityNotification.Announcement("Copied").post()
                } else {
                    actionError = client.activityMessage
                }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.subheadline.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy clipboard item")
    }

    private var settings: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.title3)
                        .frame(width: 46, height: 46)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(client.linked || client.savedPC != nil ? deviceTitle : "No PC connected")
                            .font(.headline)
                        Text(client.linked ? "Connected over Wi-Fi" : "Disconnected")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Picker(selection: $appearance) {
                    ForEach(PhoneAppearance.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { sendAudioToPC },
                    set: { enabled in
                        guard TrustedPeerStore.setBroadcastAudioEnabled(enabled) else {
                            actionError = "Porthole couldn’t save your audio setting. Try again."
                            return
                        }
                        sendAudioToPC = enabled
                    }
                )) {
                    Label("Send audio to PC", systemImage: "speaker.wave.2")
                }
            } header: {
                Text("Screen and audio")
            } footer: {
                Text(client.linked && client.fileSendPeer?.broadcastVersion != 2
                     ? "Update Porthole on your PC to receive app audio."
                     : "Send app audio to your PC while sharing your screen.")
            }

            Section("Connection features") {
                NavigationLink {
                    ConnectionSettings(feature: .input, client: client, index: index, input: input)
                } label: {
                    Label("Mouse and keyboard", systemImage: "computermouse")
                }
                NavigationLink {
                    ConnectionSettings(feature: .photos, client: client, index: index, input: input)
                } label: {
                    LabeledContent {
                        Text(index.accessLabel)
                    } label: { Label("Photo access", systemImage: "photo") }
                }
                NavigationLink {
                    ConnectionSettings(feature: .clipboard, client: client, index: index, input: input)
                } label: {
                    LabeledContent {
                        Text(client.clipboardSyncEnabled ? "On" : "Off")
                    } label: { Label("Clipboard sync", systemImage: "clipboard") }
                }
            }

            Section("File storage") {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Save received files to")
                        Text(client.saveFolderName).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "folder") }
                Button("Choose another folder", systemImage: "folder.badge.plus") { showSheet(.saveFolder) }
                if client.usesCustomSaveFolder {
                    Button("Use default folder") { client.resetSaveFolder() }
                }
                if !client.storageMessage.isEmpty {
                    Text(client.storageMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: {
                        client.fileNotificationsEnabled &&
                            client.notificationAuthorization != .denied &&
                            client.notificationAuthorization != .notDetermined
                    },
                    set: client.setFileNotificationsEnabled
                )) {
                    Label("File notifications", systemImage: "bell")
                }
                .disabled(client.notificationAuthorization == .denied)
            } footer: {
                if client.notificationAuthorization == .denied { Text("iOS has blocked notifications for Porthole.") }
            }

            Section {
                Button("Help and connection tips", systemImage: "questionmark.circle") {
                    actionError = "Open Porthole on your PC and connect both devices to the same Wi-Fi."
                }
                if client.savedPC != nil {
                    Button("Forget \(deviceTitle)", role: .destructive) { client.forgetPC() }
                }
            } footer: {
                Text("Version \(version)")
            }
        }
        .scrollContentBackground(.hidden)
        .background(phoneBackground)
        .navigationTitle("Settings")
    }

    private var manualEntry: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("PC address", text: $manualDraft.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Connection code", text: $manualDraft.code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    TextField("PC certificate fingerprint", text: $manualDraft.fingerprint, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(2...4)
                } footer: {
                    Text("Use the code and fingerprint shown on your PC.")
                }
                if let manualError {
                    Section { Text(manualError).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Connect to PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { activeSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        guard !pairingScreenIsCaptured else { return }
                        if client.connect(address: manualDraft.address, code: manualDraft.code,
                                          fingerprint: manualDraft.fingerprint.isEmpty ? nil : manualDraft.fingerprint) {
                            activeSheet = nil
                        } else {
                            manualError = client.status
                            AccessibilityNotification.Announcement(client.status).post()
                        }
                    }
                    .disabled(manualDraft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var scanSheet: some View {
        NavigationStack {
            QRScanner(onCode: applyScan, onCameraError: { error in
                scanError = error
                cameraUnavailable = true
                AccessibilityNotification.Announcement(error).post()
            })
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Text(scanError ?? "Point your camera at the connection QR code in Porthole on your PC.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    if cameraUnavailable {
                        Button("Open app settings", action: openAppSettings)
                    }
                    Button("Enter details manually") {
                        manualAfterScan = true
                        activeSheet = nil
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { activeSheet = nil } }
            }
        }
    }

    private func choiceSheet(peer: TrustedPeer, ids: [String]) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(ids.count == 1 ? "Review matching item" : "Select a matching item")
                        .font(.title2.bold())
                    Text("The selected photo or video will send its unedited original to \(peer.name), including any metadata saved in the original file.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        ForEach(Array(ids.enumerated()), id: \.element) { offset, id in
                            Button {
                                guard client.fileSendPeer?.id == peer.id, client.choiceIDs == ids else { return }
                                confirmedPhotoChoice = true
                                client.pickChoice(id)
                            } label: {
                                VStack(spacing: 8) {
                                    ChoiceThumb(id: id, number: ids.count == 1 ? nil : offset + 1)
                                    Text("Send original").font(.footnote.weight(.semibold))
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Send the unedited original to \(peer.name)")
                        }
                    }
                    .disabled(confirmedPhotoChoice || client.fileSendPeer?.id != peer.id || client.choiceIDs != ids)
                }
                .padding(20)
            }
            .navigationTitle("Confirm photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel transfer") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func arrivalBanner(_ arrival: PullClient.Arrival) -> some View {
        HStack(spacing: 12) {
            FileMark(name: arrival.name, file: arrival.file)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(arrival.name) received")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(arrival.warning ?? "Saved in \(arrival.reference?.folderName ?? "Porthole")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if arrival.reference != nil {
                Button("Open", action: openArrival)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button {
                client.clearArrival()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func applyScan(_ text: String) -> Bool {
        guard !pairingScreenIsCaptured else { return false }
        guard let url = URLComponents(string: text), url.scheme == "porthole",
              let host = url.host, !host.isEmpty, url.port == 47731,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.path.first == "/", !url.path.dropFirst().contains("/") else {
            showScanError("This is not a Porthole connection code. Try the QR code shown on your PC.")
            return false
        }
        let token = String(url.path.dropFirst())
        guard token.utf8.count == 8, token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            showScanError("The QR code does not contain a valid connection code.")
            return false
        }
        let pins = (url.queryItems ?? []).filter { $0.name == "pin" }
        guard pins.count == 1, let fingerprint = pins.first?.value else {
            showScanError("Use the current QR code on your PC, including its verification fingerprint.")
            return false
        }
        guard client.connect(address: host, code: token, fingerprint: fingerprint) else {
            showScanError(client.status)
            return false
        }
        activeSheet = nil
        return true
    }

    private func showScanError(_ message: String) {
        if scanError != message { AccessibilityNotification.Announcement(message).post() }
        scanError = message
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }


}

private struct PairingDraft {
    var address = ""
    var code = ""
    var fingerprint = ""
}

private struct SendSelection {
    let urls: [URL]
    let peer: TrustedPeer
}

private enum PhoneSheet: Identifiable {
    case manualPairing, feature(ConnectionFeature), sendPicker(TrustedPeer), sendReview(TrustedPeer)
    case qrScanner, photoChoice(TrustedPeer, [String]), received(ReceivedFile), saveFolder, clipboard(ActivityRecord)

    var id: String {
        switch self {
        case .manualPairing: "manual-pairing"
        case .feature(let feature): "feature-\(feature.id)"
        case .sendPicker: "send-picker"
        case .sendReview: "send-review"
        case .qrScanner: "qr-scanner"
        case .photoChoice: "photo-choice"
        case .received(let file): "received-\(file.id)"
        case .saveFolder: "save-folder"
        case .clipboard(let item): "clipboard-\(item.id)"
        }
    }
}

private final class ReceivedFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let folderName: String
    let referenceID: UUID
    private let release: (URL) -> Void

    init(url: URL, name: String, folderName: String, referenceID: UUID, release: @escaping (URL) -> Void) {
        self.url = url
        self.name = name
        self.folderName = folderName
        self.referenceID = referenceID
        self.release = release
    }

    // SwiftUI and any nested exporter retain the preview until presentation ends.
    deinit { release(url) }
}

private struct ReceivedFileSheet: View {
    let item: ReceivedFile
    let client: PullClient
    @Environment(\.dismiss) private var dismiss
    @State private var preview: UIImage?
    @State private var note = ""
    @State private var action: FileAction?
    @State private var savingToPhotos = false

    private enum FileAction: String, Identifiable {
        case preview, share, export
        var id: String { rawValue }
    }

    private var media: Bool { PullClient.isPhotoOrVideo(item.name) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Group {
                        if let preview {
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: media ? "photo.on.rectangle" : "doc.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 96)
                        }
                    }
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                    Text(item.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Text(note.isEmpty ? "Saved in \(item.folderName)." : note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if QLPreviewController.canPreview(item.url as NSURL) {
                        GlassCapsuleButton(title: "Open preview", systemImage: "eye", prominent: true) {
                            action = .preview
                        }
                    }
                    if media {
                        GlassCapsuleButton(title: savingToPhotos ? "Saving…" : "Save to Photos", systemImage: "photo") {
                            savingToPhotos = true
                            client.saveToPhotos(item.url) { [item] ok in
                                // Keep a provider preview alive until Photos has consumed the file.
                                withExtendedLifetime(item) {
                                    savingToPhotos = false
                                    note = ok ? "Saved to Photos" : "Unable to save to Photos. Check photo permissions and try again."
                                    AccessibilityNotification.Announcement(note).post()
                                }
                            }
                        }
                        .disabled(savingToPhotos)
                    }
                    GlassCapsuleButton(title: "Save a copy to Files", systemImage: "folder") { action = .export }
                    GlassCapsuleButton(title: "Share", systemImage: "square.and.arrow.up") { action = .share }
                }
                .padding(20)
            }
            .navigationTitle("Received file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $action) { action in
            switch action {
            case .preview: QuickLookPreview(file: item)
            case .share: ActivitySheet(file: item)
            case .export: ExportPicker(file: item)
            }
        }
        .task(id: item.id) {
            let thumbnail = await FileThumb.image(url: item.url, maxPixelSize: 960)
            if !Task.isCancelled { preview = thumbnail }
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let file: ReceivedFile

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return preview
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) { }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let file: ReceivedFile
        init(file: ReceivedFile) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { file.url as NSURL }
    }
}

private struct ExportPicker: UIViewControllerRepresentable {
    let file: ReceivedFile

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let file: ReceivedFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { [file] _, _, _, _ in withExtendedLifetime(file) { } }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private struct ChoiceThumb: View {
    let id: String
    let number: Int?
    @State private var image: UIImage?
    @State private var details: String?
    @State private var unavailable = false
    @State private var request: PHImageRequestID?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15))
                        .overlay {
                            if unavailable { Image(systemName: "photo").foregroundStyle(.secondary) }
                            else { ProgressView() }
                        }
                }
            }
            .frame(width: 132, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            if let number { Text("Option \(number)").font(.subheadline.weight(.semibold)) }
            if let details { Text(details).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if unavailable { Text("Preview unavailable").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .onAppear(perform: load)
        .onDisappear {
            if let request { PHImageManager.default().cancelImageRequest(request) }
            request = nil
        }
    }

    private func load() {
        guard request == nil else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            unavailable = true
            return
        }
        let kind = asset.mediaType == .video ? "Video" : "Photo"
        details = asset.creationDate.map { kind + " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? kind
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 280, height: 280),
                                                        contentMode: .aspectFill, options: options) { image, info in
            let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
            let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
            DispatchQueue.main.async {
                guard !cancelled else { return }
                if let image { self.image = image }
                else if !degraded { unavailable = true }
            }
        }
    }
}

/// The system picker gives the exact Photos identifier, without guessing from a
/// playback frame. The file is still exported through PhotoKit as original bytes.
struct OriginalPicker: UIViewControllerRepresentable {
    let onChoose: (String?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onChoose: onChoose) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onChoose: (String?) -> Void
        init(onChoose: @escaping (String?) -> Void) { self.onChoose = onChoose }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onChoose(results.first?.assetIdentifier)
        }
    }
}

/// A picture when the file is one, otherwise the type (PDF, ZIP) on a page.
private struct FileMark: View {
    let name: String
    var file: URL?
    var glyph: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let glyph {
                Text(glyph)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.06))
            } else {
                TypeChip(name: name)
            }
        }
        .frame(width: 36, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: file?.path) {
            image = nil
            guard let file else { return }
            let thumbnail = await FileThumb.image(url: file, maxPixelSize: 160)
            if !Task.isCancelled { image = thumbnail }
        }
    }
}

private struct TypeChip: View {
    let name: String

    private var tag: String {
        let ext = (name as NSString).pathExtension
        if ext.isEmpty { return "FILE" }
        return String(ext.prefix(4)).uppercased()
    }

    private var ink: Color {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return Color(red: 0.70, green: 0.14, blue: 0.09)
        case "zip", "7z", "rar": return Color(red: 0.48, green: 0.35, blue: 0.07)
        case "m4a", "mp3", "wav", "aac": return Color(red: 0.36, green: 0.24, blue: 0.54)
        case "doc", "docx": return Color(red: 0.18, green: 0.37, blue: 0.54)
        default: return Color(red: 0.29, green: 0.31, blue: 0.33)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            Text(tag)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(ink, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                .padding(.leading, 2)
                .padding(.bottom, 5)
        }
    }
}

enum FileThumb {
    private static let imageQueue = DispatchQueue(label: "porthole.thumbnails", qos: .utility)

    static func image(url: URL, maxPixelSize: Int) async -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp"].contains(ext) {
            return await withCheckedContinuation { continuation in
                imageQueue.async {
                    let options: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    let image = CGImageSourceCreateWithURL(url as CFURL, nil)
                        .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
                        .map { UIImage(cgImage: $0) }
                    continuation.resume(returning: image)
                }
            }
        }
        guard ["mov", "mp4", "m4v"].contains(ext) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        return await withTaskCancellationHandler {
            guard let result = try? await generator.image(at: time) else { return nil }
            return UIImage(cgImage: result.image)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }
}

/// One line of Activity: which way it went, what, and when.
private struct ActivityRow: View {
    let item: PullClient.ActivityItem
    var file: URL?
    var canOpen = false

    private var subtitle: String {
        guard let bytes = item.bytes else { return item.detail }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " · " + item.detail
    }

    private var glyph: String? {
        guard !item.isFile else { return nil }
        let title = item.title
        if title == "Picture" { return "IMG" }
        if title.hasPrefix("http://") || title.hasPrefix("https://") { return "↗" }
        return "Aa"
    }

    var body: some View {
        HStack(spacing: 12) {
            FileMark(name: item.title, file: file, glyph: glyph)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if canOpen {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(item.date, style: .time)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
