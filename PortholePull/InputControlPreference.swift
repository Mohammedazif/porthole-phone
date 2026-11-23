import Foundation

struct InputControlPreference {
    var enabled: Bool
    var screenSharingOnly: Bool

    init(defaults: UserDefaults = .standard) {
        enabled = defaults.object(forKey: "porthole.inputEnabled") as? Bool ?? true
        screenSharingOnly = defaults.object(forKey: "porthole.inputScreenSharingOnly") as? Bool ?? true
    }

    struct Update {
        let id = UUID().uuidString.lowercased()
        let enabled: Bool
        let screenSharingOnly: Bool

        private var values: String { "\(enabled ? 1 : 0) \(screenSharingOnly ? 1 : 0)" }
        var command: String { "INPUT \(id) \(values)\n" }
        var receipt: String { "INPUT OK \(id) \(values)" }
    }

    func update(verificationAvailable: Bool) -> Update {
        Update(enabled: enabled && verificationAvailable, screenSharingOnly: screenSharingOnly)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "porthole.inputEnabled")
        defaults.set(screenSharingOnly, forKey: "porthole.inputScreenSharingOnly")
    }
}
