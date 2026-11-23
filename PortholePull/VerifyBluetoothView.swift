import SwiftUI
import UIKit

struct VerifyBluetoothView: View {
    @ObservedObject var client: PullClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var captureRequested = true
    @State private var focusFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch client.inputVerificationStatus {
                    case .required, .failed:
                        idleContent
                    case .waiting:
                        ProgressView("Checking Bluetooth")
                        Text("Keep this screen open while Porthole checks the connection to \(client.deviceName).")
                    case .confirming:
                        ProgressView("Confirming with your PC")
                    case .verified:
                        Label("Bluetooth verified", systemImage: "checkmark.circle")
                        if client.inputScreenSharingOnly && client.broadcastStatus?.phase != .live {
                            Text("Start screen sharing now to use your PC’s mouse and keyboard.")
                        }
                    }
                }
            }
            .background {
                if captureRequested {
                    VerificationKeyCapture(onFocus: { focused in
                        guard captureRequested else { return }
                        if focused, scenePhase == .active, client.canVerifyInput {
                            client.beginInputVerification()
                        } else if !focused, client.inputVerificationStatus.inProgress {
                            client.cancelInputVerification(message: "Bluetooth verification lost focus.")
                        } else if !client.inputVerificationStatus.inProgress {
                            captureRequested = false
                            focusFailed = !focused
                        }
                    }, onKey: { client.captureInputVerificationKey($0) })
                    .accessibilityHidden(true)
                }
            }
            .navigationTitle("Verify Bluetooth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        client.cancelInputVerification()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(client.inputVerificationStatus.inProgress ? "Cancel" : "Close")
                }
            }
        }
        .interactiveDismissDisabled(captureRequested)
        .onChange(of: client.inputVerificationStatus) { _, status in
            if !status.inProgress { captureRequested = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                captureRequested = false
                client.cancelInputVerification(message: "Bluetooth verification was interrupted.")
            }
        }
        .onDisappear { client.cancelInputVerification() }
    }

    @ViewBuilder private var idleContent: some View {
        if captureRequested {
            ProgressView("Preparing verification")
        } else {
            if focusFailed {
                Text("Could not begin Bluetooth verification.")
            } else if !client.linked {
                Text("Reconnect to your PC to verify Bluetooth.")
            } else if case .failed(let message) = client.inputVerificationStatus {
                Text(message)
                Text("Check Bluetooth on your iPhone and make sure PC controls are available in Porthole.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Bluetooth verification is required for PC controls.")
            }
            if client.canVerifyInput {
                Button("Try again") {
                    focusFailed = false
                    captureRequested = true
                }
            }
        }
    }
}

private struct VerificationKeyCapture: UIViewRepresentable {
    let onFocus: (Bool) -> Void
    let onKey: (Int) -> Void

    func makeUIView(context: Context) -> KeyResponder {
        let result = KeyResponder()
        result.onFocus = onFocus
        result.onKey = onKey
        return result
    }

    func updateUIView(_ view: KeyResponder, context: Context) {
        view.onFocus = onFocus
        view.onKey = onKey
    }

    static func dismantleUIView(_ view: KeyResponder, coordinator: Void) {
        view.onFocus = nil
        view.onKey = nil
        view.resignFirstResponder()
    }

    final class KeyResponder: UIView {
        var onFocus: ((Bool) -> Void)?
        var onKey: ((Int) -> Void)?
        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                resignFirstResponder()
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, let onFocus = self.onFocus else { return }
                onFocus(self.becomeFirstResponder())
            }
        }

        override func resignFirstResponder() -> Bool {
            let hadFocus = isFirstResponder
            guard super.resignFirstResponder() else { return false }
            if hadFocus {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isFirstResponder else { return }
                    self.onFocus?(false)
                }
            }
            return true
        }

        private func keypadUsage(_ press: UIPress) -> Int? {
            guard let key = press.key,
                  key.modifierFlags.intersection([.alternate, .command, .control, .shift]).isEmpty else { return nil }
            let usage = Int(key.keyCode.rawValue)
            return InputVerificationAttempt.acceptsKeypadUsage(usage) ? usage : nil
        }

        private func remainingPresses(_ presses: Set<UIPress>) -> Set<UIPress> {
            Set(presses.filter { keypadUsage($0) == nil })
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let keypad = presses.compactMap { keypadUsage($0) }
            if keypad.count == 1, let usage = keypad.first { onKey?(usage) }
            let remaining = remainingPresses(presses)
            if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
        }

        override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = remainingPresses(presses)
            if !remaining.isEmpty { super.pressesChanged(remaining, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = remainingPresses(presses)
            if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = remainingPresses(presses)
            if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
        }
    }
}
