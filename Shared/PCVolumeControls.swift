import AppIntents
import Foundation

/// A tap on a Porthole volume button in Control Center or the Dynamic Island,
/// passed to the Porthole app, which holds the link to the PC. A Darwin
/// notification reaches the app whichever process runs the button's intent.
enum PCVolumeSignal {
    static let up = "local.porthole.pull.pc-volume.up"
    static let down = "local.porthole.pull.pc-volume.down"

    static func post(louder: Bool) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName((louder ? up : down) as CFString),
                                             nil, nil, true)
    }
}

/// Turns the PC's volume up or down one step. A Live Activity intent, so iOS
/// runs it in the Porthole app's process when it can.
struct PCVolumeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Change PC Volume"
    static var description = IntentDescription("Turns the PC's volume up or down while Porthole is connected to it.")

    @Parameter(title: "Louder", default: false)
    var louder: Bool

    init() {}

    init(louder: Bool) {
        self.louder = louder
    }

    func perform() async throws -> some IntentResult {
        PCVolumeSignal.post(louder: louder)
        return .result()
    }
}
