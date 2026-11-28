import ActivityKit
import AppIntents
import Foundation

/// A file going to or coming from the PC, shown as a Live Activity on the
/// Lock Screen, in Notification Center and in the Dynamic Island.
struct TransferActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 0…1 of the whole send or receive.
        var fraction: Double
        /// The file and how far it is, for example "IMG_0042.MOV · 1.2 GB of 3 GB".
        var detail: String
    }

    /// "Sending to UNKNOWN" or "Receiving from UNKNOWN".
    var title: String
    var incoming: Bool
}

extension Notification.Name {
    /// The Live Activity's Stop button; userInfo["incoming"] says which one.
    static let portholeStopTransfer = Notification.Name("porthole.stopTransfer")
}

/// The Stop button on the Live Activity. iOS runs it in Porthole itself,
/// which stops the send or receive as Cancel does (it asks nothing more:
/// the button is the person's own tap on that transfer).
struct StopTransferIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop"
    static var description = IntentDescription("Stops this file transfer.")

    @Parameter(title: "Receiving")
    var incoming: Bool

    init() {}

    init(incoming: Bool) {
        self.incoming = incoming
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .portholeStopTransfer, object: nil, userInfo: ["incoming": incoming])
        }
        return .result()
    }
}
