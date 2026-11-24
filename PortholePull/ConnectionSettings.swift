import Photos
import SwiftUI
import UIKit
#if compiler(>=6.2)
import Accessibility
#endif

enum ConnectionFeature: String, Identifiable {
    case input, photos, clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input: return "Mouse and keyboard"
        case .photos: return "Photo access"
        case .clipboard: return "Clipboard sync"
        }
    }
}

struct ConnectionSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    let feature: ConnectionFeature
    @ObservedObject var client: PullClient
    @ObservedObject var index: PhotoIndex
    @ObservedObject var input: InputDeviceMonitor
    var verifiesBluetooth = false
    @State private var showingSelectedPhotos = false
    @State private var choosingOriginal: OriginalSelection?
    @State private var settingsHelp: String?

    var body: some View {
        Form {
            switch feature {
            case .input: inputSettings
            case .photos: photoSettings
            case .clipboard: clipboardSettings
            }
        }
        .navigationTitle(feature.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if feature == .photos { index.refreshIfNeeded() } }
        .onChange(of: scenePhase) { _, phase in
            if feature == .photos, phase == .active { index.refreshIfNeeded() }
        }
        .sheet(isPresented: $showingSelectedPhotos) {
            LimitedPhotoPicker {
                showingSelectedPhotos = false
                index.requestAccessAndIndex(refresh: true)
            }
        }
        .background { if verifiesBluetooth { BluetoothAutoVerification(client: client, available: true) } }
        .sheet(item: $choosingOriginal) { selection in
            OriginalPicker { identifier in
                choosingOriginal = nil
                guard let identifier else { return }
                guard client.fileSendPeer?.id == selection.peer.id else {
                    settingsHelp = "The connected PC changed. Select the original again after reconnecting."
                    return
                }
                client.chooseOriginal(identifier)
            }
        }
        .alert("Porthole", isPresented: Binding(
            get: { settingsHelp != nil },
            set: { if !$0 { settingsHelp = nil } }
        )) {
            Button("OK", role: .cancel) { settingsHelp = nil }
        } message: {
            Text(settingsHelp ?? "")
        }
    }

    private var inputSettings: some View {
        Group {
            Section {
                Toggle("Enable mouse and keyboard", isOn: Binding(
                    get: { client.inputControlsEnabled },
                    set: { client.setInputControlsEnabled($0) }
                ))
                Toggle("Only during screen sharing", isOn: Binding(
                    get: { client.inputScreenSharingOnly },
                    set: { client.setInputScreenSharingOnly($0) }
                ))
                .disabled(!client.inputControlsEnabled)
                LabeledContent("Status", value: client.inputControlSummary)
            } header: {
                Text("PC controls")
            } footer: {
                if client.linked && (!client.inputControlSupported || !client.inputVerificationSupported) {
                    Text("Update Porthole on \(client.computerName) to apply these preferences.")
                }
            }
            Section("Input devices on iPhone") {
                LabeledContent("Mouse", value: input.mouseNames.isEmpty
                               ? (input.mouseConnected ? "Connected" : "Not detected")
                               : input.mouseNames.joined(separator: ", "))
                LabeledContent("Keyboard", value: input.keyboardName ?? (input.keyboardConnected ? "Connected" : "Not detected"))
                Button("Refresh device status") { input.refresh() }
            }
            Section {
                Text("Select Set up controls in Porthole on \(client.computerName), then pair in Bluetooth settings.")
            } header: {
                Text("Bluetooth pairing")
            }
            Section {
                Button("AssistiveTouch settings") { openAccessibilitySettings(dwell: false) }
                Button("Dwell Control settings") { openAccessibilitySettings(dwell: true) }
            } header: {
                Text("Pointer control")
            } footer: {
                Text("Enable AssistiveTouch for pointer control.")
            }
        }
    }

    private var photoSettings: some View {
        Group {
            Section("Photo library") {
                LabeledContent("Access", value: index.accessLabel)
                Text(index.status).font(.footnote).foregroundStyle(.secondary)
                if index.authorizationStatus == .notDetermined {
                    Button("Allow photo access") { index.requestAccessAndIndex(refresh: true) }
                }
                if index.authorizationStatus == .limited {
                    Button("Manage selected photos") { showingSelectedPhotos = true }
                }
                if index.authorizationStatus == .authorized || index.authorizationStatus == .limited {
                    Button("Refresh photo library") { index.requestAccessAndIndex(refresh: true) }
                }
                Button("Open app settings", action: openAppSettings)
            }
            Section {
                if let peer = client.fileSendPeer {
                    LabeledContent("Send to", value: peer.name)
                    Button("Select original") { choosingOriginal = OriginalSelection(peer: peer) }
                        .disabled(!index.ready)
                } else {
                    Text("Connect to your PC to select an original.")
                        .foregroundStyle(.secondary)
                }
                if !client.chosenOriginal.isEmpty {
                    LabeledContent("Selected file", value: client.chosenOriginal)
                    Button("Clear selection") { client.clearChosenOriginal() }
                }
            } header: {
                Text("Original file transfer")
            } footer: {
                Text("Original files may include their saved metadata.")
            }
        }
    }

    private var clipboardSettings: some View {
        Group {
            Section {
                Toggle("Clipboard sync", isOn: Binding(
                    get: { client.clipboardSyncEnabled },
                    set: { client.setClipboardSyncEnabled($0) }
                ))
                LabeledContent("Status", value: client.clipboardSummary)
            } footer: {
                Text("Share text and images with your PC.")
            }
            ClipboardHistorySettings(client: client)
            Section {
                ClipboardActions(client: client)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openAccessibilitySettings(dwell: Bool) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Task { @MainActor in
                do {
                    try await AccessibilitySettings.openSettings(for: dwell ? .dwellControl : .assistiveTouch)
                } catch {
                    showAccessibilityPath(dwell: dwell)
                }
            }
            return
        }
        #endif
        showAccessibilityPath(dwell: dwell)
    }

    private func showAccessibilityPath(dwell: Bool) {
        settingsHelp = dwell
            ? "Open Settings › Accessibility › Touch › AssistiveTouch › Dwell Control, then disable Dwell Control."
            : "Open Settings › Accessibility › Touch › AssistiveTouch, then enable AssistiveTouch."
    }
}

private struct OriginalSelection: Identifiable {
    let peer: TrustedPeer
    var id: UUID { peer.id }
}

struct ClipboardHistorySettings: View {
    @ObservedObject var client: PullClient

    var body: some View {
        Section {
            Toggle("Keep clipboard history", isOn: Binding(
                get: { client.clipboardHistoryEnabled },
                set: { client.setClipboardHistoryEnabled($0) }
            ))
        } footer: {
            Text("Keep items for up to 7 days. Turning this off clears history.")
        }
    }
}

struct ClipboardActions: View {
    @ObservedObject var client: PullClient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ClipboardSendButton(client: client)
            Text(client.clipStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
    }
}

struct ClipboardSendButton: View {
    @ObservedObject var client: PullClient

    private var enabled: Bool { client.linked && client.clipboardSyncEnabled && client.clipboardLinkReady }

    var body: some View {
        GlassCapsuleButton(title: "Send clipboard", systemImage: "clipboard", compact: true,
                           action: client.sendClipboardNow)
            .disabled(!enabled)
            .accessibilityHint("Sends the clipboard to your PC.")
    }
}

private struct LimitedPhotoPicker: UIViewControllerRepresentable {
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> LimitedPhotoPickerController {
        let controller = LimitedPhotoPickerController()
        controller.onFinish = onFinish
        return controller
    }

    func updateUIViewController(_ controller: LimitedPhotoPickerController, context: Context) {
        controller.onFinish = onFinish
    }
}

private final class LimitedPhotoPickerController: UIViewController {
    var onFinish: (() -> Void)?
    private var presentedPicker = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presentedPicker else { return }
        presentedPicker = true
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            onFinish?()
            return
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] _ in
            DispatchQueue.main.async { self?.onFinish?() }
        }
    }
}
