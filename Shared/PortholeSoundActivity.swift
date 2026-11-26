import ActivityKit
import Foundation

/// The Live Activity shown while the iPhone's sound plays on the PC: the
/// Dynamic Island carries the PC's volume buttons.
struct PortholeSoundAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var pcName: String
    }
}
