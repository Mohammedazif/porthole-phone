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

    var body: some View {
        NavigationStack {
            Form {
                Section("Screen") {
                    Button("Share screen") {
                        client.pauseKeepAlive()
                        DispatchQueue.main.async { broadcast.press() }
                    }
                    BroadcastPicker(trigger: broadcast)
                        .frame(width: 44, height: 44)
                        .opacity(0.02)
                        .allowsHitTesting(false)
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
                    Button("Load photos") { index.requestAccessAndIndex() }
                        .disabled(index.ready && index.status.hasPrefix("Ready"))
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
            if phase == .active { client.cameForward() }
            if phase == .background { client.enteredBackground() }
        }
    }
}
