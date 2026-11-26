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
/// Main thread only.
final class VolumeButtonRelay {
    private let isActive: () -> Bool
    private let press: (_ louder: Bool) -> Void
    private let stuck: () -> Void
    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var lastVolume: Float?
    private var restVolume: Float?
    private var restoring: Float?
    private var restoreCheck: DispatchWorkItem?

    init(isActive: @escaping () -> Bool, press: @escaping (_ louder: Bool) -> Void,
         stuck: @escaping () -> Void) {
        self.isActive = isActive
        self.press = press
        self.stuck = stuck
    }

    deinit { observation?.invalidate() }

    func start() {
        guard observation == nil else { return }
        installVolumeView()
        lastVolume = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            DispatchQueue.main.async { self?.volumeChanged(to: value) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        restoreCheck?.cancel()
        restoreCheck = nil
        restVolume = nil
        restoring = nil
        lastVolume = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    private func volumeChanged(to value: Float) {
        let previous = lastVolume ?? value
        lastVolume = value
        guard isActive() else {
            // Not sharing with sound on the PC: the buttons are the iPhone's again.
            restVolume = nil
            restoring = nil
            return
        }
        if let target = restoring, abs(value - target) < 0.01 {
            restoring = nil
            return  // our own correction arriving
        }
        guard abs(value - previous) >= 0.01 else { return }
        let rest = restVolume ?? previous
        restVolume = rest
        press(value > previous)
        put(rest)
    }

    private func put(_ value: Float) {
        restoring = value
        installVolumeView()
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
            stuck()
            return
        }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
        restoreCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.restoring == value else { return }
            if abs(AVAudioSession.sharedInstance().outputVolume - value) >= 0.01 {
                self.restoring = nil
                self.stuck()
            }
        }
        restoreCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: check)
    }

    /// The system slider only moves the volume while it is in a window.
    private func installVolumeView() {
        if let view = volumeView, view.window != nil { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first else { return }
        let view = volumeView ?? MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        volumeView = view
    }
}
