import SwiftUI
import UserNotifications

@main
struct PortholePullApp: App {
    init() {
        // Install before the first view appears so a cold-launch notification
        // tap can queue its file reference for ContentView to open.
        UNUserNotificationCenter.current().delegate = NoticeDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
