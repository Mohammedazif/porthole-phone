import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func testPreferences() {
    let suite = "porthole.clipboard-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let preference = ClipboardSyncPreference(defaults: defaults)
    let initial = preference.generation!
    require(preference.allows(initial), "Existing users must retain enabled sync by default.")

    preference.setEnabled(false)
    require(preference.generation == nil, "Disabled sync must reject new clipboard work.")
    require(!preference.allows(initial), "Disabling must cancel pending work.")
    require(ClipboardSyncPreference(defaults: defaults).generation == nil,
            "The disabled preference must survive a new client instance.")

    preference.setEnabled(true)
    let current = preference.generation!
    require(!preference.allows(initial), "Re-enabling must not revive old paste callbacks.")
    require(preference.allows(current), "New work must be allowed after enabling.")
    require(ClipboardSyncPreference(defaults: defaults).generation != nil,
            "The enabled preference must survive a new client instance.")

    var sends = 0
    preference.performIfAllowed(initial) { sends += 1 }
    require(sends == 0, "A stale generation must not reach the transport.")
    preference.performIfAllowed(current) { sends += 1 }
    require(sends == 1, "Current clipboard work must reach the transport exactly once.")
    preference.setEnabled(false)
    preference.performIfAllowed(current) { sends += 1 }
    require(sends == 1, "Disabled clipboard work must not reach the transport.")

    print("PASS: defaults, persistence, disable, re-enable, stale work and transport gating")
}

func testQueuedWork() {
    let suite = "porthole.clipboard-queue-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preference = ClipboardSyncPreference(defaults: defaults)
    let stale = preference.generation!
    let queue = DispatchQueue(label: "porthole.clipboard-tests")
    let release = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    queue.async {
        release.wait()
        preference.performIfAllowed(stale) {
            fatalError("Work queued before disabling must not be sent after re-enabling.")
        }
        completed.signal()
    }
    preference.setEnabled(false)
    preference.setEnabled(true)
    release.signal()
    require(completed.wait(timeout: .now() + 5) == .success, "Queued work did not complete.")
    print("PASS: queued clipboard work remains canceled across disable/re-enable")
}

testPreferences()
testQueuedWork()
