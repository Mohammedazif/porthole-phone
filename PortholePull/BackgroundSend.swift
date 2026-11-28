import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Keeps sending after the person leaves Porthole or locks the iPhone. On
/// iOS 26 a send started in Porthole continues as a background task; iOS
/// shows its progress on the Lock Screen and in the Dynamic Island with the
/// title and subtitle set here. Earlier iOS gives the usual short grace.
final class BackgroundSend {
    static let shared = BackgroundSend()
    /// The same for a file arriving from the PC.
    static let receiving = BackgroundSend()
    /// Listed in Info.plist under BGTaskSchedulerPermittedIdentifiers.
    static let identifierPrefix = "local.porthole.pull.send"

    private var task: AnyObject?
    private var onExpire: (() -> Void)?
    private var title = ""
    private var subtitle = ""
    private var fraction = 0.0
    private var active = false

    /// From the foreground, as the person taps Send. `onExpire` runs if iOS
    /// stops the work; sending then pauses and can continue later.
    func begin(title: String, subtitle: String, onExpire: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.end(success: false)
            self.active = true
            self.onExpire = onExpire
            self.title = title
            self.subtitle = subtitle
            self.fraction = 0
            #if compiler(>=6.2)
            guard #available(iOS 26.0, *) else { return }
            let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let continued = task as? BGContinuedProcessingTask, let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(continued)
            }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            // If iOS declines, sending still runs while Porthole is open.
            try? BGTaskScheduler.shared.submit(request)
            #endif
        }
    }

    func update(fraction: Double, subtitle: String) {
        DispatchQueue.main.async {
            guard self.active else { return }
            self.fraction = min(1, max(0, fraction))
            self.subtitle = subtitle
            #if compiler(>=6.2)
            guard #available(iOS 26.0, *), let task = self.task as? BGContinuedProcessingTask else { return }
            task.progress.completedUnitCount = Int64(self.fraction * 1000)
            task.updateTitle(self.title, subtitle: subtitle)
            #endif
        }
    }

    /// iOS is keeping the send going in the background. Main thread.
    var isRunning: Bool { task != nil }

    func finish(success: Bool) {
        DispatchQueue.main.async { self.end(success: success) }
    }

    private func end(success: Bool) {
        active = false
        onExpire = nil
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
        }
        #endif
        task = nil
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        guard active else {
            task.setTaskCompleted(success: true) // already done
            return
        }
        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(fraction * 1000)
        task.updateTitle(title, subtitle: subtitle)
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let expire = self.onExpire
                self.onExpire = nil
                self.active = false
                self.task = nil
                expire?()
            }
            task.setTaskCompleted(success: false)
        }
    }
    #endif

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
