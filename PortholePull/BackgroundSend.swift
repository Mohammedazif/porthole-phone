import ActivityKit
import Foundation
import UIKit
import UserNotifications

/// The progress of a file going to the PC (or, as `receiving`, coming from
/// it) on the Lock Screen, in Notification Center and in the Dynamic Island,
/// as a Live Activity with a Stop button. Porthole keeps running in the
/// background while paired, so it keeps the progress current itself.
/// iOS lets a Live Activity start only while Porthole is open.
final class BackgroundSend {
    static let shared = BackgroundSend(incoming: false)
    /// The same for a file arriving from the PC.
    static let receiving = BackgroundSend(incoming: true)

    private let incoming: Bool
    private var activity: Activity<TransferActivityAttributes>?
    private var onExpire: ((Bool) -> Void)?
    private var title = ""
    private var detail = ""
    private var fraction = 0.0
    private var active = false
    private var shownAt = Date.distantPast
    private var stopObserver: NSObjectProtocol?

    private init(incoming: Bool) {
        self.incoming = incoming
        stopObserver = NotificationCenter.default.addObserver(forName: .portholeStopTransfer, object: nil,
                                                              queue: .main) { [weak self] note in
            guard let self, (note.userInfo?["incoming"] as? Bool) == self.incoming, self.active else { return }
            DiagnosticLog.note("progress: Stop tapped on the Lock Screen (\(self.incoming ? "receiving" : "sending"))")
            let expire = self.onExpire
            self.end(success: false)
            expire?(true)
        }
    }

    /// From the foreground, as the person taps Send (or as a file starts
    /// arriving). `onExpire(true)` runs when the person taps Stop.
    func begin(title: String, subtitle: String, onExpire: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.end(success: false)
            self.active = true
            self.onExpire = onExpire
            self.title = title
            self.detail = subtitle
            self.fraction = 0
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                DiagnosticLog.note("progress: Live Activities are turned off for Porthole in Settings")
                return
            }
            let state = TransferActivityAttributes.ContentState(fraction: 0, detail: subtitle)
            do {
                self.activity = try Activity.request(
                    attributes: TransferActivityAttributes(title: title, incoming: self.incoming),
                    content: ActivityContent(state: state, staleDate: nil), pushType: nil)
                self.shownAt = Date()
                DiagnosticLog.note("progress: shown on the Lock Screen for \(title)")
            } catch {
                DiagnosticLog.note("progress: iOS refused the Live Activity for \(title): \(error)")
            }
        }
    }

    func update(fraction: Double, subtitle: String) {
        DispatchQueue.main.async {
            guard self.active else { return }
            self.fraction = min(1, max(0, fraction))
            self.detail = subtitle
            // About once a second: iOS limits how often it redraws one.
            guard let activity = self.activity, Date().timeIntervalSince(self.shownAt) >= 1 else { return }
            self.shownAt = Date()
            let state = TransferActivityAttributes.ContentState(fraction: self.fraction, detail: subtitle)
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        }
    }

    /// The Live Activity is showing. Main thread.
    var isRunning: Bool { activity != nil }

    func finish(success: Bool) {
        DispatchQueue.main.async { self.end(success: success) }
    }

    private func end(success: Bool) {
        active = false
        onExpire = nil
        guard let activity else { return }
        self.activity = nil
        let state = TransferActivityAttributes.ContentState(fraction: success ? 1 : fraction,
                                                             detail: success ? "Done" : detail)
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: success ? .after(.now + 4) : .immediate)
        }
    }

    static var appInForeground: Bool {
        if Thread.isMainThread { return UIApplication.shared.applicationState == .active }
        return DispatchQueue.main.sync { UIApplication.shared.applicationState == .active }
    }
}

/// Notifications about sending to the PC. Shown when Porthole is not on
/// screen; tapping one opens Porthole where it continues.
enum SendNotice {
    static let key = "porthole.send"
    enum Action: String { case resume, handoff, open }

    static func sent(to pc: String, first: String, more: Int, thumbnail: URL?) {
        post(title: "Sent to \(pc)", body: more > 0 ? "\(first) and \(more) more" : first,
             action: .open, thumbnail: thumbnail)
    }

    static func paused(pc: String, thumbnail: URL?) {
        post(title: "Sending paused", body: "\(pc) isn’t available. Tap to continue.",
             action: .resume, thumbnail: thumbnail)
    }

    static func stopped(thumbnail: URL?) {
        post(title: "Sending paused", body: "Tap to continue sending.", action: .resume, thumbnail: thumbnail)
    }

    static func post(title: String, body: String, action: Action, thumbnail: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [key: action.rawValue]
        content.threadIdentifier = key
        if let thumbnail, let attachment = try? UNNotificationAttachment(identifier: "thumbnail", url: thumbnail) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: "\(key).\(action.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clear() {
        let ids = [Action.resume, .handoff, .open].map { "\(key).\($0.rawValue)" }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
}
