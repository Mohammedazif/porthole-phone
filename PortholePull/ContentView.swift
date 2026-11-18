import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var index = PhotoIndex()
    @StateObject private var client = PullClient()

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Leave this app open. On the PC, drag a fullscreen photo off the Porthole window. The original file follows the cursor when one photo matches.")
                }
            }
            .navigationTitle("Porthole")
        }
        .onAppear { client.prepare() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { client.cameForward() }
        }
    }
}
