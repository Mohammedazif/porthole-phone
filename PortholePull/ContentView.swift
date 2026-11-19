import ReplayKit
import SwiftUI

/// The system broadcast button, set to this app's extension so one tap starts it.
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = "local.porthole.pull.broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var index = PhotoIndex()
    @StateObject private var client = PullClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("Screen") {
                    HStack(spacing: 12) {
                        BroadcastButton()
                            .frame(width: 44, height: 44)
                        Text("Share screen")
                    }
                    Text("Sends what this iPhone shows to Porthole over Wi-Fi, Photos bars and pop-ups included. Turn Screen Mirroring off while sharing, and keep this app connected below.")
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
