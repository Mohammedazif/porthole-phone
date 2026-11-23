import SwiftUI
import UserNotifications

enum PhoneAppearance: String, CaseIterable {
    case system, light, dark

    static let preferenceKey = "porthole.appearance"

    var label: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct PortholePullApp: App {
    @AppStorage(PhoneAppearance.preferenceKey) private var appearance: PhoneAppearance = .system

    init() {
        // Install before the first view appears so a cold-launch notification
        // tap can queue its file reference for ContentView to open.
        UNUserNotificationCenter.current().delegate = NoticeDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(appearance.colorScheme)
        }
    }
}
