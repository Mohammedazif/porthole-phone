import AVFoundation
import Photos
import PhotosUI
import ReplayKit
import SwiftUI
import UIKit

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
                presentArrival()
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
        .onChange(of: client.arrival?.id) { _, _ in
            presentArrival()
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

    /// Opens the file that just arrived, then drops the banner so it cannot stay up.
    private func presentArrival() {
        guard scenePhase == .active, let arrival = client.arrival, let file = arrival.file else { return }
        received = ReceivedFile(url: file, name: arrival.name)
        client.clearArrival()
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
                                Text("Porthole").font(.headline)
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

    private var connected: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected").font(.subheadline).foregroundStyle(.secondary)
                        Text("Porthole").font(.title2.bold())
                        Text(client.address).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    GlassIconButton(systemImage: "arrow.left.arrow.right", label: "Switch PC") {
                        enteringPC = true
                    }
                }
                shareLens
                Text("Tap, then Start Broadcast. Everything on screen, including sound, appears on the PC.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 0) {
                    statusRow("Mouse and keyboard", client.status, false)
                    statusRow("Photos", index.status, false)
                    statusRow("Clipboard", client.clipStatus.isEmpty ? "On while this app is open" : client.clipStatus, true)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                HStack(spacing: 12) {
                    GlassCapsuleButton(title: "Send files", systemImage: "doc") { explainingSend = true }
                    GlassCapsuleButton(title: "Send clipboard", systemImage: "doc.on.clipboard") {
                        client.sendClipboardNow()
                    }
                }
            }
            .padding(20)
        }
    }

    /// Sharing is on only once iOS says this screen is being broadcast, not on the tap.
    private func updateCapture() {
        let now = UIScreen.main.isCaptured
        if now && !captured {
            shareStarted = Date()
            hideSharing = false
        }
        captured = now
    }

    private var shareLens: some View {
        Button {
            if captured {
                hideSharing = false
            } else {
                // Silent playback disables the system button; stop it, then open the sheet.
                client.pauseKeepAlive()
                broadcast.press()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Ink.lens)
                    .frame(width: 168, height: 168)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                    .modifier(LensGlass())
                VStack(spacing: 6) {
                    portholeMark
                    Text(captured ? "Sharing" : "Share screen")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var portholeMark: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 36, height: 36)
            Capsule().fill(.white.opacity(0.85)).frame(width: 16, height: 3).offset(y: -4)
            Capsule().fill(.white.opacity(0.55)).frame(width: 12, height: 3)
            Capsule().fill(.white.opacity(0.35)).frame(width: 8, height: 3).offset(y: 4)
        }
    }

    private var sharingScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            GlassIconButton(systemImage: "chevron.left", label: "Back") { hideSharing = true }
            Text("LIVE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text("Sharing to")
                .foregroundStyle(.secondary)
            Text("Porthole")
                .font(.largeTitle.bold())
            TimelineView(.periodic(from: shareStarted, by: 30)) { context in
                let minutes = Int(context.date.timeIntervalSince(shareStarted) / 60)
                Text("\(minutes) \(minutes == 1 ? "minute" : "minutes") shared")
                    .font(.title3.weight(.semibold))
            }
            Text("You can leave this app. Everything on screen, including notifications, shows on the PC until you stop.")
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                statusRow("Picture", "Live", false)
                statusRow("Sound", "On the PC", false)
                statusRow("Controls", "Use the PC window", true)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer()
            GlassCapsuleButton(title: "Stop sharing", systemImage: "stop.fill", prominent: true, tint: .red) {
                // Opens the system sheet with Stop Broadcast; the screen follows iOS.
                broadcast.press()
            }
        }
        .padding(20)
    }

    private var filteredHistory: [PullClient.ActivityItem] {
        client.history.filter { activityFilter == 0 || (activityFilter == 1) == $0.isFile }
    }

    private var activity: some View {
        List {
            Picker("Show", selection: $activityFilter) {
                Text("All").tag(0)
                Text("Files").tag(1)
                Text("Clipboard").tag(2)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if activityFilter != 2 {
                Section {
                    if client.chosenOriginal.isEmpty {
                        Text("If a photo you drag off the PC window isn't the only match, pick it here. Then drag again, and the PC takes the one you chose.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(client.chosenOriginal, systemImage: "checkmark.circle.fill")
                        Text("On the PC, drag the photo out of the Porthole window.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Cancel selection", role: .cancel) { client.clearChosenOriginal() }
                    }
                    GlassCapsuleButton(title: "Pick from library", systemImage: "photo.on.rectangle") {
                        choosingOriginal = true
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Photo for the PC")
                }
            }
            Section {
                if filteredHistory.isEmpty {
                    Text(activityFilter == 2 ? "Copy something on either side and it shows here."
                                             : "Files you send or receive show here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredHistory) { item in
                    if let path = item.path, let url = client.fileURL(named: path) {
                        Button {
                            received = ReceivedFile(url: url, name: item.title)
                        } label: {
                            ActivityRow(item: item, canOpen: true)
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
            if activityFilter != 1 {
                Section("Clipboard") {
                    Text(client.clipStatus.isEmpty ? "Copies move both ways while Porthole is open." : client.clipStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    GlassCapsuleButton(title: "Send clipboard", systemImage: "doc.on.clipboard") {
                        client.sendClipboardNow()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
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
                LabeledContent("Files to the PC", value: "PC folder")
                LabeledContent("Files from the PC", value: "In this app")
                Text("The PC saves files in Downloads unless you choose another folder in its Settings. Files from the PC stay here so you can save or share them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Forget this PC", role: .destructive) {
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
                Text("You can paste the whole line from the PC into the address. Port 47731.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            Button {
                presentArrival()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(arrival.name) received")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("Tap to save or share")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
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
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .task(id: arrival.id) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if scenePhase == .active, client.arrival?.id == arrival.id {
                client.clearArrival()
            }
        }
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
                Text("In Files, Photos, Voice Memos, or Mail, select the items and tap Share, then Porthole. The PC keeps the original file. It goes to Downloads unless you choose another folder in the PC app's Settings.")
                    .foregroundStyle(.secondary)
                Text("To send one photo the PC could not match, use Activity › Pick from library, then drag that card out of the PC window.")
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

    private func statusRow(_ name: String, _ state: String, _ last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(name)
                Spacer()
                Text(state)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if !last { Divider().padding(.leading, 16) }
        }
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

/// One line of Activity: which way it went, what, and when.
private struct ActivityRow: View {
    let item: PullClient.ActivityItem
    var canOpen = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isFile ? (item.incoming ? "arrow.down.doc" : "arrow.up.doc")
                                          : "doc.on.clipboard")
                .font(.body)
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
