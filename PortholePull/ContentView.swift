import ReplayKit
import PhotosUI
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Screen") {
                    Button("Share screen") {
                        client.pauseKeepAlive()
                        DispatchQueue.main.async { broadcast.press() }
                    }
                    .background {
                        BroadcastPicker(trigger: broadcast)
                            .frame(width: 44, height: 44)
                            .opacity(0.02)
                            .allowsHitTesting(false)
                    }
                    Text("Sends what this iPhone shows to Porthole over Wi-Fi, Photos bars and pop-ups included. Screen Mirroring can stay off. Keep this app connected below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("This PC") {
                    TextField("Address from F1 help", text: $client.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Code from F1 help", text: $client.code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Text("You can paste the whole F1 line into the address. Port 47731.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Library") {
                    Text(index.status)
                    Button(index.ready ? "Refresh library" : "Load photos") {
                        index.requestAccessAndIndex(refresh: true)
                    }
                }
                Section("Original file") {
                    Button("Choose original") { choosingOriginal = true }
                    if client.chosenOriginal.isEmpty {
                        Text("If a photo or video will not drag, choose it here. Then drag the original-file card out of the Porthole window on your PC. It sends exactly the original you chose, including from iCloud.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "doc")
                                .font(.largeTitle)
                            Text(client.chosenOriginal)
                                .font(.headline)
                            Text("On your PC, hold and drag this card onto the desktop or a folder.")
                                .font(.footnote)
                        }
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .foregroundStyle(Color.black)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        Button("Cancel selection", role: .cancel) { client.clearChosenOriginal() }
                    }
                }
                Section("Link") {
                    Text(client.status)
                    Button("Connect") {
                        client.bind(index: index)
                        client.connect()
                    }
                }
                Section {
                    Text("Open this once, wait until it says Ready and Connected, then open the photo. Drag that picture off the Porthole window. The original file follows the cursor.")
                }
            }
            .navigationTitle("Porthole")
        }
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
