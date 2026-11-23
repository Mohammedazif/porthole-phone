import Foundation

/// Shared by the UI and transport queues. A revision invalidates clipboard work
/// that was queued before synchronization was disabled, including paste callbacks.
final class ClipboardSyncPreference {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key = "porthole.clipboardSyncEnabled"
    private var enabled: Bool
    private var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: key) as? Bool ?? true
    }

    var generation: Int? {
        lock.lock()
        defer { lock.unlock() }
        return enabled ? revision : nil
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        revision += 1
        lock.unlock()
        defaults.set(value, forKey: key)
    }

    func allows(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && revision == generation
    }

    /// Keep disabling in sync with the nonblocking transport send.
    func performIfAllowed(_ generation: Int, action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if enabled && revision == generation { action() }
    }
}
