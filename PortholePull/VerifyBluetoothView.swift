import SwiftUI
import UIKit

struct BluetoothAutoVerification: View {
    @ObservedObject var client: PullClient
    @Environment(\.scenePhase) private var scenePhase
    let available: Bool
    @State private var captureRequested = false

    private var eligiblePeer: UUID? {
        guard available, scenePhase == .active, client.inputControlsEnabled,
              client.inputSettingsApplied, client.inputVerificationSupported,
              client.inputVerificationStatus != .verified else { return nil }
        return client.fileSendPeer?.id
    }

    var body: some View {
        Color.clear.background {
            if captureRequested {
                VerificationKeyCapture(onFocus: { focused in
                    guard captureRequested else { return }
                    if focused, eligiblePeer != nil, client.canVerifyInput {
                        client.beginInputVerification()
                    } else if !focused {
                        captureRequested = false
                        client.cancelInputVerification()
                    }
                }, onKey: client.captureInputVerificationKey)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: eligiblePeer) {
            guard let peer = eligiblePeer else { return }
            // Let navigation and system Bluetooth dialogs return first responder before checking.
            try? await Task.sleep(for: .milliseconds(500))
            while !Task.isCancelled, eligiblePeer == peer {
                if client.canVerifyInput { captureRequested = true }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onChange(of: client.inputVerificationStatus) { _, status in
            if !status.inProgress { captureRequested = false }
        }
        .onChange(of: eligiblePeer) { _, peer in
            if peer == nil, captureRequested {
                captureRequested = false
                client.cancelInputVerification()
            }
        }
        .onDisappear {
            if captureRequested { client.cancelInputVerification() }
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
