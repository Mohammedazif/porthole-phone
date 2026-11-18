import SwiftUI

struct ContentView: View {
    @StateObject private var index = PhotoIndex()
    @StateObject private var client = PullClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("This PC") {
                    TextField("Address, such as 192.168.1.20", text: $client.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Code from Porthole help", text: $client.code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Text("Port 47731. The code is on the PC in F1 help.")
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
                    .disabled(!index.ready)
                }
                Section {
                    Text("Leave this app open. On the PC, drag a fullscreen photo off the Porthole window. The original file follows the cursor when one photo matches.")
                }
            }
            .navigationTitle("Porthole")
        }
    }
}
