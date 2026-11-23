import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let suite = "porthole.input-tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
var preference = InputControlPreference(defaults: defaults)
require(preference.enabled && preference.screenSharingOnly,
        "New and existing installations must default to controls only during screen sharing.")
let defaultUpdate = preference.update(verificationAvailable: true)
require(defaultUpdate.command == "INPUT \(defaultUpdate.id) 1 1\n", "The default policy must match the PC protocol.")
require(defaultUpdate.receipt == "INPUT OK \(defaultUpdate.id) 1 1", "Match both the latest ID and values.")
let unavailable = preference.update(verificationAvailable: false)
require(unavailable.command == "INPUT \(unavailable.id) 0 1\n", "Disable input when Bluetooth verification is unavailable.")
require(defaultUpdate.id != unavailable.id, "Each preference update gets a fresh ID.")
preference.enabled = false
preference.save(defaults: defaults)
let disabled = InputControlPreference(defaults: defaults)
require(!disabled.enabled && disabled.screenSharingOnly, "Disabling must persist independently of screen-only mode.")
let disabledUpdate = disabled.update(verificationAvailable: true)
require(disabledUpdate.command == "INPUT \(disabledUpdate.id) 0 1\n", "Send an explicit disable to the PC.")
preference.enabled = true
preference.screenSharingOnly = false
preference.save(defaults: defaults)
let manual = InputControlPreference(defaults: defaults)
require(manual.enabled && !manual.screenSharingOnly, "Explicit control without sharing must persist.")
let manualUpdate = manual.update(verificationAvailable: true)
require(manualUpdate.command == "INPUT \(manualUpdate.id) 1 0\n", "Manual mode must be explicit in the protocol.")
print("PASS: safe defaults, persistence, explicit disable, manual mode and matching acknowledgements")

var verification = InputVerificationAttempt()
require(UUID(uuidString: verification.id) != nil && verification.id == verification.id.lowercased(),
        "Each attempt uses a lowercase request ID.")
for usage in [0x1e, 0x27, 0x58, 0x63] {
    require(!InputVerificationAttempt.acceptsKeypadUsage(usage) && verification.acceptKeypadUsage(usage) == nil,
            "Number-row, keypad Enter, and punctuation cannot enter a proof.")
}
let usages = [0x62, 0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x62, 0x59, 0x59, 0x62, 0x61]
for usage in usages.dropLast() {
    require(verification.acceptKeypadUsage(usage) == nil, "Wait for all 16 keypad events.")
}
require(verification.acceptKeypadUsage(usages[15]) == "0123456789001109", "Preserve zeroes and repeats.")
for usage in usages {
    require(verification.acceptKeypadUsage(usage) == nil, "An attempt can submit only one proof.")
}
require(!InputVerificationStatus.verified.inProgress && InputVerificationStatus.confirming.inProgress,
        "Cancel only an active verification.")
print("PASS: Bluetooth verification accepts one proof from 16 keypad events")
