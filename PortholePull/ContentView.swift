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
        for case let button as UIButton in picker.subviews {
            button.isEnabled = true
            button.sendActions(for: .touchUpInside)
        }
    }
}

struct BroadcastPicker: UIViewRepresentable {
    let trigger: BroadcastTrigger

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = "local.porthole.pull.broadcast"
        picker.showsMicrophoneButton = false
        trigger.picker = picker
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        trigger.picker = picker
        for case let button as UIButton in picker.subviews {
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
    @State private var sharing = false
    @State private var shareStarted = Date()
    @State private var explainingSend = false
    @State private var scanning = false
    @State private var shareFile: ShareFile?
    @State private var activityFilter = 0

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        TabView {
            NavigationStack {
                Group {
                    if sharing && client.linked {
                        sharingScreen
                    } else if client.linked {
                        connected
                    } else {
                        findPC
                    }
                }
                .background(Color(white: 0.953))
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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                client.cameForward()
                index.refreshIfNeeded()
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
        .safeAreaInset(edge: .top) {
            if let arrival = client.arrival {
                arrivalBanner(arrival)
            }
        }
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
                                .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Text(client.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                glassButton("Scan the code on the PC", prominent: true) { scanning = true }
                glassButton("Enter address and code", prominent: false) { enteringPC = true }
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
                    glassButton("Switch", prominent: false, expands: false) { enteringPC = true }
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
                .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                HStack(spacing: 12) {
                    glassButton("Send files", prominent: false) { explainingSend = true }
                    glassButton("Send clipboard", prominent: false) { client.sendClipboardNow() }
                }
            }
            .padding(20)
        }
    }

    private var shareLens: some View {
        Button {
            client.pauseKeepAlive()
            shareStarted = Date()
            sharing = true
            DispatchQueue.main.async { broadcast.press() }
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.82))
                    .frame(width: 168, height: 168)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                VStack(spacing: 6) {
                    portholeMark
                    Text("Share screen")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .background {
            BroadcastPicker(trigger: broadcast)
                .frame(width: 44, height: 44)
                .opacity(0.02)
                .allowsHitTesting(false)
        }
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
            Button { sharing = false } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
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
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer()
            Button {
                broadcast.press()
                sharing = false
            } label: {
                Text("Stop sharing")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.red.opacity(0.16), in: Capsule())
                    .overlay { Capsule().strokeBorder(.red.opacity(0.35), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(20)
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
            if activityFilter != 2 {
                Section {
                    Button("Pick from library") { choosingOriginal = true }
                    if client.chosenOriginal.isEmpty {
                        Text("If a dragged photo is not the only match, pick it here. Then drag that card out of the Porthole window. It sends the original you chose.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(client.chosenOriginal)
                        Text("On the PC, hold and drag this choice onto the desktop or a folder.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Cancel selection", role: .cancel) { client.clearChosenOriginal() }
                    }
                } header: {
                    Text("Original file")
                }
            }
            if activityFilter != 1 {
                Section("Clipboard") {
                    Text(client.clipStatus.isEmpty ? "Nothing copied yet." : client.clipStatus)
                    Button("Send clipboard") { client.sendClipboardNow() }
                }
            }
            Section("Library") {
                Text(index.status)
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
                Button("Open iPhone Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            Section("Sharing") {
                LabeledContent("Clipboard sync", value: client.clipStatus.isEmpty ? "On while connected" : "On")
                LabeledContent("Photos", value: index.accessLabel)
                Text("Files shared from this iPhone save to Downloads on the PC.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Forget this PC", role: .destructive) {
                    sharing = false
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
            Text(arrival.openPhotos ? "\(arrival.name) is in Photos" : "\(arrival.name) is in Files")
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Open") { openArrival(arrival) }
                .font(.subheadline.weight(.semibold))
            Button("Close") { client.clearArrival() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background)
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

    private func openArrival(_ arrival: PullClient.Arrival) {
        if arrival.openPhotos, let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
            return
        }
        if let file = arrival.file {
            shareFile = ShareFile(url: file)
        }
    }

    private var sendFilesHelp: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Share from any app")
                    .font(.title2.bold())
                Text("In Files, Photos, Voice Memos, or Mail, select the items and tap Share, then Porthole. The PC keeps the original file, name and all, in Downloads.")
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

    private func glassButton(_ title: String, prominent: Bool, expands: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: expands ? .infinity : nil)
                .padding(.horizontal, expands ? 0 : 16)
                .padding(.vertical, 12)
                .background {
                    if prominent {
                        Capsule().fill(.black.opacity(0.88))
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    Capsule().strokeBorder(.white.opacity(prominent ? 0.28 : 0.7), lineWidth: 1)
                }
                .foregroundStyle(prominent ? .white : .primary)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }
}

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
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
