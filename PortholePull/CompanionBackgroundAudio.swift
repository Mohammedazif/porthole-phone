import AVFoundation
import Foundation

/// Maintains the paired companion link while Porthole is in the background.
/// The audio session mixes with the current route and always outputs silence.
final class CompanionBackgroundAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer
    private var observers: [NSObjectProtocol] = []
    private(set) var requested = false
    private var starting = false
    private var interrupted = false
    private var sessionActive = false

    init?() {
        let frames: AVAudioFrameCount = 8_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for index in 0..<Int(frames) { samples[index] = 0 }
        self.buffer = buffer

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in self?.restartIfNeeded() })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.restartIfNeeded() })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in self?.audioInterrupted(note) })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        stopPlayback()
    }

    func setRequested(_ value: Bool) {
        guard requested != value else { return }
        requested = value
        if value {
            restartIfNeeded()
        } else {
            interrupted = false
            stopPlayback()
        }
    }

    private func restartIfNeeded() {
        guard requested, !starting, !interrupted, (!sessionActive || !engine.isRunning || !player.isPlaying) else { return }
        starting = true
        defer { starting = false }
        let session = AVAudioSession.sharedInstance()
        do {
            if !sessionActive {
                try session.setCategory(.playback, options: [.mixWithOthers])
                try session.setActive(true)
                sessionActive = true
            }
            player.stop()
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        } catch {
            stopPlayback()
        }
    }

    private func audioInterrupted(_ note: Notification) {
        guard requested, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let interruption = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch interruption {
        case .began:
            interrupted = true
            sessionActive = false
            player.stop()
            engine.stop()
        case .ended:
            interrupted = false
            restartIfNeeded()
        @unknown default:
            break
        }
    }

    private func stopPlayback() {
        player.stop()
        engine.stop()
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
