import AVFoundation
import Photos
import PhotosUI
import ReplayKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Holds the system broadcast button. iOS disables that button while this app's
/// silent playback is running, which is the whole time mirroring is off.
final class BroadcastTrigger: ObservableObject {
    fileprivate weak var picker: RPSystemBroadcastPickerView?

    func press() {
        guard let picker else { return }
        for button in Self.buttons(in: picker) {
            button.isEnabled = true
            button.sendActions(for: .touchUpInside)
        }
    }

    /// The system button may sit deeper than the picker's first level of views.
    static func buttons(in view: UIView) -> [UIButton] {
        view.subviews.flatMap { sub -> [UIButton] in
            if let button = sub as? UIButton { return [button] }
            return buttons(in: sub)
        }
    }
}

struct BroadcastPicker: UIViewRepresentable {
    let trigger: BroadcastTrigger

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        // From this app's own ID: a signing tool may have renamed both, and a stale name
        // leaves the sheet without Porthole to pick.
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "local.porthole.pull") + ".broadcast"
        picker.showsMicrophoneButton = false
        trigger.picker = picker
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        trigger.picker = picker
        for button in BroadcastTrigger.buttons(in: picker) {
            button.isEnabled = true
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var index = PhotoIndex()
    @StateObject private var client = PullClient()
    @StateObject private var broadcast = BroadcastTrigger()
    @State private var choosingOriginal = false
    @State private var enteringPC = false
    /// iOS is broadcasting this screen (the Start Broadcast sheet was accepted).
    @State private var captured = false
    /// The user went Back from the Sharing screen while the broadcast goes on.
    @State private var hideSharing = false
    @State private var shareStarted = Date()
    @State private var explainingSend = false
    @State private var scanning = false
    @State private var shareFile: ShareFile?
    @State private var received: ReceivedFile?
    @State private var activityFilter = 0

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        TabView {
            NavigationStack {
                Group {
                    if captured && !hideSharing && client.linked {
                        sharingScreen
                    } else if client.linked {
                        connected
                    } else {
                        findPC
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
            .tabItem { Label("Porthole", systemImage: "circle.circle") }

            NavigationStack { activity }
                .tabItem { Label("Activity", systemImage: "clock") }

            NavigationStack { settings }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.primary)
        .onAppear {
            client.bind(index: index)
            client.prepare()
            index.requestAccessAndIndex()
            updateCapture()
            openPendingNotice()
        }
        // The system broadcast button lives here, outside the screens that come and go:
        // pressing it after its screen was swapped out showed no Start Broadcast sheet.
        .background(alignment: .topLeading) {
            BroadcastPicker(trigger: broadcast)
                .frame(width: 44, height: 44)
                .opacity(0.02)
                .allowsHitTesting(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            updateCapture()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                client.cameForward()
                index.refreshIfNeeded()
                updateCapture()
            }
            if phase == .background { client.enteredBackground() }
        }
        .sheet(isPresented: $choosingOriginal) {
            OriginalPicker { identifier in
                choosingOriginal = false
                if let identifier { client.chooseOriginal(identifier) }
            }
        }
        .sheet(isPresented: $enteringPC) { manualEntry }
        .sheet(isPresented: $explainingSend) { sendFilesHelp }
        .sheet(isPresented: $scanning) { scanSheet }
        .sheet(isPresented: Binding(
            get: { client.choiceIDs.count == 2 },
            set: { shown in
                if !shown, client.choiceIDs.count == 2 { client.pickChoice(nil) }
            }
        )) { choiceSheet }
        .sheet(item: $shareFile) { item in
            ActivitySheet(url: item.url)
        }
        .sheet(item: $received) { item in
            ReceivedFileSheet(item: item, client: client)
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

    private func openPendingNotice() {
        guard let name = NoticeDelegate.pendingName else { return }
        NoticeDelegate.pendingName = nil
        guard let url = client.fileURL(named: name) else { return }
        received = ReceivedFile(url: url, name: name)
    }

    private func openArrival() {
        guard let arrival = client.arrival, let file = arrival.file else { return }
        received = ReceivedFile(url: file, name: arrival.name)
    }

    private var findPC: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find your PC")
                        .font(.largeTitle.bold())
                    Text("Porthole on this Wi-Fi. Tap your PC, then enter the code shown on it.")
                        .foregroundStyle(.secondary)
                }
                if !client.nearby.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On this Wi-Fi")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(client.nearby) { pc in
                            Button {
                                if !client.selectNearby(address: pc.address) {
                                    enteringPC = true
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pc.name).font(.headline)
                                        Text(pc.address).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Use").font(.subheadline.weight(.semibold))
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !client.address.isEmpty {
                    Button { client.connect() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.deviceName.isEmpty ? "Saved device" : client.deviceName).font(.headline)
                                Text(client.address).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Connect").font(.subheadline.weight(.semibold))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Text(client.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                GlassCapsuleButton(title: "Scan code on PC screen", systemImage: "qrcode.viewfinder",
                                   prominent: true) { scanning = true }
                GlassCapsuleButton(title: "Enter address and code") { enteringPC = true }
                Text("Don't see your PC? Open Porthole on it and keep both on the same Wi-Fi. Porthole needs Local Network access, in Settings › Porthole.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var deviceTitle: String {
        client.deviceName.isEmpty ? "This device" : client.deviceName
    }

    private var photosLine: String {
        switch index.accessLabel {
        case "Allowed": return "Full access, so originals can be sent"
        case "Limited": return "Limited access. Only the photos you picked can be sent"
        default: return index.accessLabel
        }
    }

    private var connected: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(red: 0.09, green: 0.50, blue: 0.24)).frame(width: 7, height: 7)
                            Text("Connected")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color(red: 0.09, green: 0.50, blue: 0.24))
                        }
                        Text(deviceTitle)
                            .font(.system(size: 32, weight: .bold))
                    }
                    Spacer()
                    GlassIconButton(systemImage: "arrow.left.arrow.right", label: "Switch PC") {
                        enteringPC = true
                    }
                }
                shareStage
                VStack(spacing: 0) {
                    linkRow("Mouse and keyboard", "Pair in Settings › Bluetooth", green: false) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    linkRow("Photos", photosLine, green: false) { index.requestAccessAndIndex() }
                    linkRow("Clipboard sync", client.clipStatus.isEmpty ? "On, both ways" : client.clipStatus, green: false, last: true) {}
                }
                .background(cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(spacing: 12) {
                    actionCard("Send files", systemImage: "doc") { explainingSend = true }
                    actionCard("Send clipboard", systemImage: "doc.on.clipboard") { client.sendClipboardNow() }
                }
            }
            .padding(20)
        }
    }

    private var cardFill: Color {
        Color(.secondarySystemGroupedBackground)
    }

    /// Sharing is on only once iOS says this screen is being broadcast, not on the tap.
    private func updateCapture() {
        let now = UIScreen.main.isCaptured
        if now && !captured {
            shareStarted = Date()
            hideSharing = false
        }
        captured = now
        client.setScreenCaptured(now)
    }

    private var shareStage: some View {
        Button {
            if captured {
                hideSharing = false
            } else {
                client.pauseKeepAlive()
                broadcast.press()
            }
        } label: {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.06))
                        .frame(width: 168, height: 168)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                        .frame(width: 168, height: 168)
                    ZStack {
                        VStack(spacing: 10) {
                            Image(systemName: "iphone")
                                .font(.title2.weight(.semibold))
                                .overlay {
                                    Image(systemName: "arrow.up")
                                        .font(.caption2.bold())
                                        .offset(y: -1)
                                }
                            Text(captured ? "Sharing" : "Share screen")
                                .font(.headline)
                        }
                        .foregroundStyle(.white)
                        portholeStroke(top: 34, right: 48, width: 4, height: 22, box: 176)
                        portholeStroke(top: 44, right: 36, width: 4, height: 22, box: 176)
                    }
                    .frame(width: 176, height: 176)
                }
                Text("Tap, then Start Broadcast. Everything on screen, including sound, appears on the PC.")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var sharingScreen: some View {
        VStack(spacing: 22) {
            HStack {
                GlassIconButton(systemImage: "chevron.left", label: "Back") { hideSharing = true }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("LIVE").font(.caption.weight(.bold))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.red.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
            }
            VStack(spacing: 4) {
                Text("Sharing to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(deviceTitle)
                    .font(.system(size: 32, weight: .bold))
            }
            TimelineView(.periodic(from: shareStarted, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(shareStarted)))
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04))
                        .frame(width: 264, height: 264)
                    Circle()
                        .fill(colorScheme == .dark ? Color(red: 0.13, green: 0.145, blue: 0.165)
                                                   : Color(red: 0.886, green: 0.894, blue: 0.910))
                        .frame(width: 240, height: 240)
                    ZStack {
                        Circle()
                            .fill(colorScheme == .dark ? Color(red: 0.09, green: 0.098, blue: 0.106) : Color.white)
                        portholeStroke(top: 38, right: 62, width: 5, height: 28, box: 220)
                        portholeStroke(top: 50, right: 46, width: 5, height: 28, box: 220)
                        VStack(spacing: 4) {
                            Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                                .font(.system(size: 40, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                            Text("minutes shared")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(red: 0.64, green: 0.64, blue: 0.64))
                        }
                    }
                    .frame(width: 220, height: 220)
                }
            }
            HStack(spacing: 10) {
                statCard("Picture", "60 fps")
                statCard("Sound", "On PC")
                statCard("Controls", "Paired")
            }
            Text("You can leave this app. Everything on screen, including notifications, shows on the PC until you stop.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                broadcast.press()
            } label: {
                Text("Stop sharing")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.red.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// One stroke of the Porthole mark. Both strokes are the same length.
    private func portholeStroke(top: CGFloat, right: CGFloat, width: CGFloat, height: CGFloat, box: CGFloat) -> some View {
        Capsule()
            .fill(Color(red: 0.639, green: 0.639, blue: 0.639))
            .frame(width: width, height: height)
            .rotationEffect(.degrees(40))
            .position(x: box - right - width / 2, y: top + height / 2)
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

    private func linkRow(_ title: String, _ detail: String, green: Bool, last: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(green ? Color(red: 0.09, green: 0.50, blue: 0.24) : .secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                if !last { Divider().padding(.leading, 16) }
            }
        }
        .buttonStyle(.plain)
    }

    private func actionCard(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
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

    private var activity: some View {
        List {
            Picker("Show", selection: $activityFilter) {
                Text("Received").tag(0)
                Text("Sent").tag(1)
                Text("Clipboard").tag(2)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Section {
                if filteredHistory.isEmpty {
                    Text(activityFilter == 2 ? "Copy something on either side and it shows here."
                         : activityFilter == 0 ? "Files from \(client.deviceName.isEmpty ? "the other device" : client.deviceName) show here."
                         : "Files you send show here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredHistory) { item in
                    if let path = item.path, let url = client.fileURL(named: path) {
                        Button {
                            received = ReceivedFile(url: url, name: item.title)
                        } label: {
                            ActivityRow(item: item, file: url, canOpen: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ActivityRow(item: item, canOpen: false)
                    }
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    if !client.history.isEmpty {
                        Button("Clear") { client.clearHistory() }
                            .font(.footnote)
                            .textCase(nil)
                    }
                }
            }
            if activityFilter == 2 {
                Section("Clipboard") {
                    Text(client.clipStatus.isEmpty ? "Copies move both ways while Porthole is open." : client.clipStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    GlassCapsuleButton(title: "Send clipboard", systemImage: "doc.on.clipboard") {
                        client.sendClipboardNow()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    PasteButton(supportedContentTypes: [.plainText, .utf8PlainText, .image, .url]) { providers in
                        client.sendPasted(providers)
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("Activity")
    }

    private var settings: some View {
        List {
            Section("Control from the PC") {
                check("AssistiveTouch on", "Accessibility › Touch › AssistiveTouch. Shows the pointer.")
                check("Dwell Control off", "In AssistiveTouch. Otherwise the pointer taps by itself.")
                Text("iOS does not tell apps whether AssistiveTouch or Dwell is on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                check("Pair Porthole", "Settings › Bluetooth › Other Devices.")
                GlassCapsuleButton(title: "Open iPhone Settings", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section("Sharing") {
                LabeledContent("Clipboard sync", value: client.clipStatus.isEmpty ? "On while connected" : "On")
                LabeledContent("Photos", value: index.accessLabel)
                LabeledContent("Files from \(client.deviceName.isEmpty ? "the device" : client.deviceName)", value: "In this app")
                Text("Files from \(client.deviceName.isEmpty ? "the device" : client.deviceName) stay in this app so you can save or share them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Forget \(client.deviceName.isEmpty ? "this device" : client.deviceName)", role: .destructive) {
                    client.forgetPC()
                }
            } footer: {
                Text("Version \(version)")
            }
        }
        .navigationTitle("Settings")
    }

    private var manualEntry: some View {
        NavigationStack {
            Form {
                TextField("Address from the PC", text: $client.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                TextField("Code from the PC", text: $client.code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            .navigationTitle("This PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { enteringPC = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        client.connect()
                        enteringPC = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var scanSheet: some View {
        NavigationStack {
            QRScanner { text in
                scanning = false
                applyScan(text)
            }
            .ignoresSafeArea()
            .navigationTitle("Scan the PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { scanning = false }
                }
            }
        }
    }

    private var choiceSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Which photo is on the PC?")
                    .font(.title2.bold())
                Text("Two library photos look alike. Pick the one to send.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    ForEach(client.choiceIDs, id: \.self) { id in
                        Button { client.pickChoice(id) } label: {
                            ChoiceThumb(id: id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Neither") { client.pickChoice(nil) }
            }
            .padding(20)
            .navigationTitle("Two photos")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func arrivalBanner(_ arrival: PullClient.Arrival) -> some View {
        HStack(spacing: 12) {
            FileMark(name: arrival.name, file: arrival.file)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(arrival.name) received")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Saved to Files › Porthole")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if arrival.file != nil {
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
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func applyScan(_ text: String) {
        guard let url = URL(string: text), url.scheme == "porthole",
              let host = url.host, url.port == 47731 else {
            client.status = "That code is not a Porthole PC."
            return
        }
        let token = url.lastPathComponent
        guard token.count == 8 else {
            client.status = "That code is not a Porthole PC."
            return
        }
        client.address = host
        client.code = token
        client.connect()
    }

    private var sendFilesHelp: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Share from any app")
                    .font(.title2.bold())
                Text("In Files, Photos, Voice Memos, or Mail, select the items and tap Share, then Porthole. \(client.deviceName.isEmpty ? "The device" : client.deviceName) keeps the original file.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Send files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { explainingSend = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func check(_ name: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(help).font(.footnote).foregroundStyle(.secondary)
        }
    }

}

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ReceivedFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
}

private struct ReceivedFileSheet: View {
    let item: ReceivedFile
    let client: PullClient
    @Environment(\.dismiss) private var dismiss
    @State private var preview: UIImage?
    @State private var note = "Kept in this app. Save it or share it."
    @State private var share: ShareFile?
    @State private var exporting = false

    private var media: Bool { PullClient.isPhotoOrVideo(item.name) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: media ? "film" : "doc.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(item.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if media {
                    GlassCapsuleButton(title: "Save to Photos", systemImage: "photo", prominent: true) {
                        client.saveToPhotos(item.url) { ok in
                            note = ok ? "Saved to Photos" : "Allow Photos for Porthole, then try Save again."
                        }
                    }
                } else {
                    GlassCapsuleButton(title: "Save to Files", systemImage: "folder", prominent: true) {
                        exporting = true
                    }
                }
                GlassCapsuleButton(title: "Share", systemImage: "square.and.arrow.up") {
                    share = ShareFile(url: item.url)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Received")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $share) { file in
            ActivitySheet(url: file.url)
        }
        .sheet(isPresented: $exporting) {
            ExportPicker(url: item.url)
        }
        .onAppear(perform: loadPreview)
    }

    private func loadPreview() {
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp"].contains(ext) {
            preview = UIImage(contentsOfFile: item.url.path)
            return
        }
        guard ["mov", "mp4", "m4v"].contains(ext) else { return }
        let asset = AVAsset(url: item.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
            guard let image else { return }
            let picture = UIImage(cgImage: image)
            DispatchQueue.main.async { self.preview = picture }
        }
    }
}

private struct ExportPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ChoiceThumb: View {
    let id: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear(perform: load)
    }

    private func load() {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 280, height: 280),
                                              contentMode: .aspectFill, options: options) { image, _ in
            self.image = image
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
            image = file.flatMap { FileThumb.image(url: $0) }
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

private enum FileThumb {
    static func image(url: URL) -> UIImage? {
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
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// One line of Activity: which way it went, what, and when.
private struct ActivityRow: View {
    let item: PullClient.ActivityItem
    var file: URL?
    var canOpen = false

    private var glyph: String? {
        guard !item.isFile else { return nil }
        let title = item.title
        if title == "Picture" { return "IMG" }
        if title.hasPrefix("http://") || title.hasPrefix("https://") { return "↗" }
        return "Aa"
    }

    var body: some View {
        HStack(spacing: 12) {
            FileMark(name: item.title, file: item.isFile ? file : nil, glyph: glyph)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.detail)
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
