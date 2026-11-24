import GameController
import SwiftUI

/// Reports connected input devices without claiming they belong to the selected PC.
final class InputDeviceMonitor: ObservableObject {
    @Published private(set) var mouseConnected = false
    @Published private(set) var keyboardConnected = false
    @Published private(set) var mouseNames: [String] = []
    @Published private(set) var keyboardName: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [Notification.Name.GCMouseDidConnect, .GCMouseDidDisconnect,
                     .GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var summary: String {
        switch (mouseConnected, keyboardConnected) {
        case (true, true): return "Mouse and keyboard connected"
        case (true, false): return "Mouse connected"
        case (false, true): return "Keyboard connected"
        case (false, false): return "Setup required"
        }
    }

    func refresh() {
        let mice = GCMouse.mice()
        let keyboard = GCKeyboard.coalesced
        mouseConnected = !mice.isEmpty
        keyboardConnected = keyboard != nil
        mouseNames = mice.compactMap { $0.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let name = keyboard?.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
        keyboardName = name?.isEmpty == false ? name : nil
    }
}
