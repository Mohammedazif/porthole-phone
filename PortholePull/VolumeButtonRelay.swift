import AVFoundation
import MediaPlayer
import UIKit

/// Experiment: while the screen is shared and its sound plays on the PC, the
/// iPhone's volume buttons change the PC's volume instead of the iPhone's.
///
/// iOS gives an app no volume button events, so this watches the system
/// volume (which needs Porthole's audio session active, as it is in the
/// background), reports each step as a press, and puts the iPhone's volume
/// back where it was through a hidden system volume slider. At zero a
/// volume-down press changes nothing, so iOS reports nothing for it.
/// Notes go to the PC's log, since that is the log we can read while testing.
/// Main thread only.
final class VolumeButtonRelay {
    private let inactiveReason: () -> String?
    private let press: (_ louder: Bool) -> Void
    private let stuck: () -> Void
    private let note: (String) -> Void
    private var observation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var volumeView: MPVolumeView?
    /// Each source reports every change, with slightly different numbers
    /// (the session in 1/16 steps, the system notice rounded), so each keeps
    /// its own last value and one press is counted once.
    private var lastBySource: [String: Float] = [:]
    private var lastPress: (at: Date, source: String)?
    private var restVolume: Float?
    private var restoring: Float?
    private var restoreCheck: DispatchWorkItem?
    private var heardFrom: Set<String> = []
    private var notesLeft = 0

    /// Less than one iPhone volume step (1/16), more than the sources differ.
    private static let sameLevel: Float = 0.04

    init(inactiveReason: @escaping () -> String?, press: @escaping (_ louder: Bool) -> Void,
         stuck: @escaping () -> Void, note: @escaping (String) -> Void) {
        self.inactiveReason = inactiveReason
        self.press = press
        self.stuck = stuck
        self.note = note
    }

    deinit {
        observation?.invalidate()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Builds the hidden system volume slider. iOS builds it only once the
    /// view is laid out in a window, which may not happen in the background.
    func prepare() {
        installVolumeView()
    }

    func start() {
        guard observation == nil else { return }
        installVolumeView()
        let session = AVAudioSession.sharedInstance()
        lastBySource = [:]
        lastPress = nil
        heardFrom = []
        notesLeft = 40
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            DispatchQueue.main.async { self?.volumeChanged(to: value, from: "session") }
        }
        // iOS also posts these while a system volume view is in a window;
        // they may arrive where the session's own report does not.
        for name in ["SystemVolumeDidChange", "AVSystemController_SystemVolumeDidChangeNotification"] {
            notificationObservers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main) { [weak self] notification in
                let info = notification.userInfo ?? [:]
                let raw = info["Volume"] ?? info["AVSystemController_AudioVolumeNotificationParameter"]
                guard let value = (raw as? NSNumber)?.floatValue else { return }
                self?.volumeChanged(to: value, from: "system")
            })
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.observation != nil else { return }
            self.installVolumeView()
            let ready = self.slider() != nil
            self.send(note: "watching at \(Self.percent(session.outputVolume)), slider \(ready ? "ready" : "missing")")
        }
    }

    /// Stops watching. The hidden slider stays in the window for next time.
    func stop() {
        observation?.invalidate()
        observation = nil
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers = []
        restoreCheck?.cancel()
        restoreCheck = nil
        restVolume = nil
        restoring = nil
        lastBySource = [:]
        lastPress = nil
    }

    private func volumeChanged(to value: Float, from source: String) {
        if heardFrom.insert(source).inserted { send(note: "first volume report from \(source)") }
        let previous = lastBySource[source] ?? value
        lastBySource[source] = value
        if let target = restoring, abs(value - target) < Self.sameLevel {
            return  // our own correction arriving, from either source
        }
        guard abs(value - previous) >= 0.01 else { return }
        if let reason = inactiveReason() {
            // Not sharing with sound on the PC: the buttons are the iPhone's again.
            restVolume = nil
            restoring = nil
            send(note: "iPhone volume \(Self.percent(value)) left alone: \(reason)")
            return
        }
        let now = Date()
        if let last = lastPress, last.source != source, now.timeIntervalSince(last.at) < 0.2 {
            return  // the other source reporting the same press
        }
        lastPress = (now, source)
        let rest = restVolume ?? previous
        restVolume = rest
        press(value > previous)
        put(rest)
    }

    private func put(_ value: Float) {
        restoring = value
        installVolumeView()
        guard let slider = slider() else {
            restoring = nil
            send(note: "no system volume slider")
            stuck()
            return
        }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
        restoreCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.restoring == value else { return }
            self.restoring = nil
            let now = AVAudioSession.sharedInstance().outputVolume
            if abs(now - value) >= Self.sameLevel {
                self.send(note: "volume stayed at \(Self.percent(now)), wanted \(Self.percent(value))")
                self.stuck()
            }
        }
        restoreCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: check)
    }

    private func send(note text: String) {
        guard notesLeft > 0 else { return }
        notesLeft -= 1
        note(text)
    }

    private static func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }

    private func slider() -> UISlider? {
        guard let view = volumeView else { return nil }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return Self.findSlider(in: view)
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        for child in view.subviews {
            if let slider = child as? UISlider { return slider }
            if let slider = findSlider(in: child) { return slider }
        }
        return nil
    }

    /// The system slider only moves the volume while it is in a window.
    private func installVolumeView() {
        if let view = volumeView, view.window != nil { return }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        // On screen at almost no opacity: iOS skips building views placed
        // far outside the window.
        let view = volumeView ?? MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        volumeView = view
    }
}
