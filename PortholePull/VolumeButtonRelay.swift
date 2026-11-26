import AVFoundation
import MediaPlayer
import UIKit

/// While the screen is shared with sound on "PC", the iPhone stays silent and
/// its volume buttons change the PC's volume.
///
/// The shared app's sound reaches the PC over Wi-Fi at full level whatever
/// the iPhone's volume, so on engaging this saves the iPhone's volume and
/// holds it at zero, and puts it back when sharing ends or the choice
/// changes. iOS gives an app no volume button events, so each press is read
/// from the system volume notice and the level is put back to zero through a
/// hidden system volume slider. Notes go to the PC's log, the log we can read
/// while testing. Main thread only.
final class VolumeButtonRelay {
    private let inactiveReason: () -> String?
    private let press: (_ louder: Bool) -> Void
    private let stuck: () -> Void
    private let note: (String) -> Void
    private var observation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var volumeView: MPVolumeView?
    /// The session reports in 1/16 steps and the system notice rounds, so
    /// each source keeps its own last level.
    private var lastBySource: [String: Float] = [:]
    private var engaged = false
    /// The iPhone's own volume, kept across launches so a level this relay
    /// set (zero) is never taken for the person's choice.
    private static let ownVolumeKey = "porthole.volume-buttons.own-volume"
    private static let holdingKey = "porthole.volume-buttons.holding"
    private var ownVolume: Float? {
        get { (UserDefaults.standard.object(forKey: Self.ownVolumeKey) as? NSNumber)?.floatValue }
        set { UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: Self.ownVolumeKey) }
    }
    private var lastFloorPress: (at: Date, sequence: Int?)?
    private var restoring: Float?
    private var restoreCheck: DispatchWorkItem?
    private var heardFrom: Set<String> = []
    private var lastReason: String?
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
        timer?.invalidate()
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
        heardFrom = []
        lastReason = nil
        lastFloorPress = nil
        notesLeft = 60
        let current = session.outputVolume
        if current > 0.01, !UserDefaults.standard.bool(forKey: Self.holdingKey) { ownVolume = current }
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            DispatchQueue.main.async { self?.volumeChanged(to: value, from: "session", reason: nil, sequence: nil) }
        }
        // iOS also posts these while a system volume view is in a window. They
        // carry the reason, and may come even when a press can't move the level.
        // (The older AVSystemController name would report each press twice.)
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("SystemVolumeDidChange"), object: nil, queue: .main) { [weak self] notification in
            let info = notification.userInfo ?? [:]
            guard let value = (info["Volume"] as? NSNumber)?.floatValue else { return }
            let reason = info["Reason"] as? String
            let sequence = (info["SequenceNumber"] as? NSNumber)?.intValue
            self?.volumeChanged(to: value, from: "system", reason: reason, sequence: sequence)
        })
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.async { [weak self] in
            guard let self, self.observation != nil else { return }
            self.installVolumeView()
            self.send(note: "watching at \(Self.percent(session.outputVolume)), slider \(self.slider() != nil ? "ready" : "missing")")
            self.evaluate()
        }
    }

    /// Stops watching, giving the iPhone its volume back first.
    func stop() {
        disengage()
        observation?.invalidate()
        observation = nil
        timer?.invalidate()
        timer = nil
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers = []
        restoreCheck?.cancel()
        restoreCheck = nil
        restoring = nil
        lastBySource = [:]
    }

    /// Engages while sharing with sound on the PC, and lets go otherwise.
    private func evaluate() {
        let reason = inactiveReason()
        if reason == nil, !engaged {
            engaged = true
            let current = AVAudioSession.sharedInstance().outputVolume
            // Zero is not taken as the person's level: it is what this relay
            // holds, and what an interrupted hold could have left behind.
            if current > 0.01, !UserDefaults.standard.bool(forKey: Self.holdingKey) { ownVolume = current }
            if ownVolume == nil { ownVolume = 0.5 }
            UserDefaults.standard.set(true, forKey: Self.holdingKey)
            send(note: "engaged: iPhone volume \(Self.percent(ownVolume ?? 0)) remembered, held at 0%")
            put(0)
        } else if let reason, engaged {
            send(note: "released: \(reason)")
            disengage()
        } else if let reason, !engaged, UserDefaults.standard.bool(forKey: Self.holdingKey) {
            // Porthole stopped while holding (quit, or a crash): give the level back now.
            engaged = true
            send(note: "released after a restart: \(reason)")
            disengage()
        } else if let reason, reason != lastReason {
            send(note: "idle: \(reason)")
        }
        lastReason = reason
    }

    private func disengage() {
        guard engaged else { return }
        engaged = false
        UserDefaults.standard.set(false, forKey: Self.holdingKey)
        let own = ownVolume ?? 0.5
        send(note: "iPhone volume put back to \(Self.percent(own))")
        put(own)
    }

    private var systemReportsNoted = 0

    private func volumeChanged(to value: Float, from source: String, reason: String?, sequence: Int?) {
        if heardFrom.insert(source).inserted { send(note: "first volume report from \(source)") }
        if source == "system", systemReportsNoted < 6 {
            systemReportsNoted += 1
            send(note: "system report \(Self.percent(value)), reason \(reason ?? "none")")
        }
        let explicit = reason == "ExplicitVolumeChange"
        let previous = lastBySource[source] ?? value
        lastBySource[source] = value
        evaluate()
        guard engaged else {
            // The person's own level, unless it is this relay putting one back.
            if value > 0.01, restoring.map({ abs(value - $0) >= Self.sameLevel }) ?? true,
               !UserDefaults.standard.bool(forKey: Self.holdingKey) {
                ownVolume = value
            }
            return
        }
        // One press, two reports: the system notice counts when it comes.
        if source == "session" && heardFrom.contains("system") { return }
        if let target = restoring, abs(value - target) < Self.sameLevel { return }  // our own correction
        if abs(value - previous) >= 0.01 {
            press(value > previous)
            put(0)
        } else if source == "system", explicit, value < 0.01 {
            // At zero a volume-down press can't move the level, but iOS still
            // says so, twice: count one press per sequence number, or per moment.
            let now = Date()
            if let last = lastFloorPress,
               (sequence != nil && last.sequence == sequence) || now.timeIntervalSince(last.at) < 0.12 {
                return
            }
            lastFloorPress = (now, sequence)
            press(false)
        }
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
        // In the window at almost no opacity: iOS skips building views placed
        // far outside it.
        let view = volumeView ?? MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        volumeView = view
    }
}
