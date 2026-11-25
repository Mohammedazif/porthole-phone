import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Network
import ReplayKit
import VideoToolbox

/// Supplies H.264 Annex-B frames to the paired PC over its verified transport.
final class SampleHandler: RPBroadcastSampleHandler {
    private struct FrameTicket {
        let id = UUID()
        let connectionID: UUID
        let forceKey: Bool
        let ptsNs: UInt64
        /// The PSCR 4 turn message: how the phone is turned (for the PC's
        /// pointer), then iOS's own tag and the captured size, for the PC log.
        let turn: Data
    }

    private struct SentPacket {
        let sentAt: DispatchTime
        let video: Bool
        let hasAudioSignal: Bool
    }

    // Connection state and frame reservations belong to this queue. ReplayKit
    // invokes its handler methods serially, so it owns the encoder and pixel pool.
    private let queue = DispatchQueue(label: "porthole.broadcast")
    private var peer: TrustedPeer?
    private var link: NWConnection?
    private var connectionID = UUID()
    private var active = false
    private var paused = false
    private var ready = false
    private var failed = false
    private var needKey = true
    private var attempts = 0
    private var connectDeadline: DispatchTime?
    private var reconnectAt: DispatchTime?
    private var watchdog: DispatchSourceTimer?
    private var encoding: [UUID: DispatchTime] = [:]
    private var awaitingACK: [SentPacket] = []
    private var lastReport: (phase: BroadcastPhase, message: String?, audioSent: Bool, time: DispatchTime)?
    private var lastAcknowledgedFrame: DispatchTime?
    private var lastKeyframeSent: DispatchTime?
    private var lastAcknowledgedAudio: DispatchTime?
    private var firstFrameDeadline: DispatchTime?
    private var ticketDeadline: DispatchTime?
    private var deliveryStopped = false
    private var broadcastEndAction: (() -> Void)?
    private var lostFrames = 0
    private var sentTurn: Data?
    private var audio = BroadcastAudio()
    private var preferencesCheckedAt: DispatchTime?
    private var sendAppAudio = false

    private var session: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var lastTimestamp: Double?
    private var lastOrientation: CGImagePropertyOrientation?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat: OSType = 0
    private lazy var imageContext = CIContext(options: [.cacheIntermediates: false])

    private let minInterval = 1.0 / 24.0
    private let maxOutstanding = 3
    private let videoBacklogLimit = DispatchTimeInterval.milliseconds(240)
    private let packetTimeout = DispatchTimeInterval.seconds(5)
    private let longEdge = 1080
    private let frameRate = 24
    private let bitrate = 3_500_000
    // Match PH_SCREEN_FRAME_MAX in the PC receiver.
    private static let maxFrameBytes = 8 * 1024 * 1024

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        preferencesCheckedAt = nil
        queue.async {
            self.active = true
            self.paused = false
            self.failed = false
            self.deliveryStopped = false
            self.lastReport = nil
            self.ticketDeadline = nil
            self.attempts = 0
            guard let pairing = TrustedPeerStore.load(),
                  let peer = TrustedPeerStore.broadcastPeer(matching: pairing) else {
                self.fail("Pair with a trusted PC in Porthole before sharing your screen.")
                return
            }
            self.peer = peer
            TrustedPeerStore.clearBroadcastStop(peer: peer)
            self.report(.connecting)
            self.startWatchdog()
            self.connect()
        }
    }

    override func broadcastPaused() {
        queue.sync {
            guard active, !deliveryStopped else { return }
            paused = true
            encoding.removeAll()
            if !ready { disconnect() }
            report(.reconnecting, message: "Screen sharing paused.")
        }
        audio = BroadcastAudio()
        resetEncoder()
    }

    override func broadcastResumed() {
        resetEncoder()
        queue.async {
            guard self.active, !self.deliveryStopped else { return }
            self.paused = false
            self.attempts = 0
            self.needKey = true
            self.report(.reconnecting)
            if self.ready {
                self.firstFrameDeadline = nil
            } else {
                self.connect()
            }
        }
    }

    override func broadcastFinished() {
        let endSent = DispatchSemaphore(value: 0)
        queue.sync {
            active = false
            stopWatchdog()
            sendBroadcastEnd { endSent.signal() }
        }
        _ = endSent.wait(timeout: .now() + .milliseconds(400))
        queue.sync {
            completeBroadcastEnd()
            disconnect()
            if !failed { report(.ended) }
            peer = nil
        }
        resetEncoder()
    }

    private func resetEncoder() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        pool = nil
        transfer = nil
        lastTimestamp = nil
        lastOrientation = nil
    }

    private func connect() {
        guard active, !paused, !deliveryStopped, link == nil, let peer else { return }
        guard var current = TrustedPeerStore.load(), current.samePairing(as: peer) else {
            fail("The trusted PC changed. Start sharing again from Porthole.")
            return
        }
        current = TrustedPeerStore.broadcastPeer(matching: current) ?? peer
        guard current.channelTicket != nil else {
            waitForTicket()
            return
        }
        self.peer = current
        ticketDeadline = nil
        attempts += 1
        reconnectAt = nil
        connectDeadline = .now() + .seconds(8)
        let id = connectionID
        let target = current
        let connection = TrustedPeerTransport.connection(to: target, port: 47732)
        link = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.active, self.link === connection,
                  self.connectionID == id else { return }
            switch state {
            case .ready:
                TrustedPeerTransport.authenticate(connection: connection, peer: target) { [weak self, weak connection] authenticated in
                    guard let self, let connection, self.active, self.link === connection,
                          self.connectionID == id else { return }
                    guard authenticated, TrustedPeerStore.load()?.samePairing(as: target) == true,
                          !TrustedPeerStore.shouldStopBroadcast(peer: peer) else {
                        self.retry("The PC did not authenticate the screen connection.")
                        return
                    }
                    let version = target.screenProtocolVersion
                    connection.send(content: Data("PSCR \(version)\n".utf8), completion: .contentProcessed { [weak self, weak connection] error in
                        guard let self, let connection, self.active, self.link === connection,
                              self.connectionID == id else { return }
                        if error != nil {
                            self.retry("The PC did not accept the screen connection.")
                            return
                        }
                        self.connectDeadline = nil
                        self.firstFrameDeadline = .now() + .seconds(10)
                        self.ready = true
                        self.watch(connection, id: id)
                    })
                }
            case .failed, .cancelled:
                self.retry("Could not verify or reach the paired PC.")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func watch(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.link === connection,
                  self.connectionID == id else { return }
            if self.broadcastEndAction != nil {
                if data?.last == 0x45 || complete || error != nil {
                    self.completeBroadcastEnd()
                } else {
                    self.watch(connection, id: id)
                }
                return
            }
            guard self.active else { return }
            if let data, !data.isEmpty {
                guard data.allSatisfy({ $0 == 0x41 }), data.count <= self.awaitingACK.count else {
                    self.retry("The PC sent an invalid screen acknowledgement.")
                    return
                }
                let acknowledgedVideo = self.awaitingACK.prefix(data.count).contains { $0.video }
                if self.awaitingACK.prefix(data.count).contains(where: \.hasAudioSignal) {
                    self.lastAcknowledgedAudio = .now()
                }
                self.awaitingACK.removeFirst(data.count)
                self.attempts = 0
                if acknowledgedVideo {
                    self.firstFrameDeadline = nil
                    self.lastAcknowledgedFrame = .now()
                    if !self.paused { self.report(.live) }
                } else if let report = self.lastReport, report.phase == .live {
                    self.report(.live)
                }
            }
            if complete || error != nil {
                self.retry("The PC closed the screen connection.")
                return
            }
            self.watch(connection, id: id)
        }
    }

    private func disconnect() {
        let old = link
        link = nil
        ready = false
        needKey = true
        connectionID = UUID()
        connectDeadline = nil
        firstFrameDeadline = nil
        reconnectAt = nil
        lastAcknowledgedFrame = nil
        lastKeyframeSent = nil
        sentTurn = nil
        lastAcknowledgedAudio = nil
        lostFrames = 0
        encoding.removeAll()
        awaitingACK.removeAll()
        old?.stateUpdateHandler = nil
        old?.cancel()
    }

    private func retry(_ reason: String) {
        disconnect()
        guard active, !paused else { return }
        guard attempts < 8 else {
            fail(reason)
            return
        }
        report(.reconnecting, message: reason)
        reconnectAt = .now() + .seconds(min(5, max(1, attempts)))
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func waitForTicket() {
        if ticketDeadline == nil { ticketDeadline = .now() + .seconds(60) }
        if let deadline = ticketDeadline, DispatchTime.now() >= deadline {
            fail("Reconnect your PC in Porthole to resume sharing.")
        } else {
            report(.reconnecting, message: "Waiting for the same PC to reconnect.")
        }
    }

    private func checkHealth() {
        guard active, let peer else { return }
        if TrustedPeerStore.shouldStopBroadcast(peer: peer) || deliveryStopped {
            stopRequestedBroadcast()
            return
        }
        guard let pairing = TrustedPeerStore.load(), pairing.samePairing(as: peer) else {
            fail("The trusted PC changed. Start sharing again from Porthole.")
            return
        }
        let current = TrustedPeerStore.broadcastPeer(matching: pairing) ?? pairing
        // A verified screen connection is independent of the foreground companion socket.
        if !ready, current.channelTicket == nil, peer.channelTicket == nil {
            if link != nil { disconnect() }
            waitForTicket()
            return
        }
        if !ready, let ticket = current.channelTicket, ticket != peer.channelTicket {
            disconnect()
            attempts = 0
            report(.reconnecting)
            connect()
            return
        }
        if paused {
            report(.reconnecting, message: "Screen sharing paused.")
            return
        }
        let now = DispatchTime.now()
        if let deadline = connectDeadline, now >= deadline {
            retry("Timed out connecting to the paired PC.")
        } else if let packet = awaitingACK.first, now >= packet.sentAt + packetTimeout {
            retry("The PC stopped acknowledging screen frames.")
        } else if let expiry = firstFrameDeadline, now >= expiry {
            retry("The PC did not acknowledge the first screen frame.")
        } else if encoding.values.contains(where: { now >= $0 + packetTimeout }) {
            // ReplayKit owns the encoder. End the broadcast rather than leaving
            // a stuck compression callback attached across reconnect attempts.
            fail("The video encoder stopped returning frames.")
        } else if lostFrames >= frameRate {
            fail("The video encoder could not deliver screen frames.")
        } else if let lastAcknowledgedFrame, now >= lastAcknowledgedFrame + .seconds(5) {
            report(.waitingForFrames, message: "Waiting for screen changes.")
        } else if let when = reconnectAt, now >= when {
            connect()
        } else if let status = lastReport, status.phase == .connecting || status.phase == .reconnecting {
            report(status.phase, message: status.message)
        }
    }

    private func report(_ phase: BroadcastPhase, message: String? = nil) {
        let now = DispatchTime.now()
        let audioSent = lastAcknowledgedAudio.map { now < $0 + .seconds(2) } ?? false
        if let lastReport, lastReport.phase == phase, lastReport.message == message, lastReport.audioSent == audioSent,
           now < lastReport.time + .seconds(2) { return }
        lastReport = (phase, message, audioSent, now)
        TrustedPeerStore.publishBroadcast(peer: peer, phase: phase, message: message, audioSent: audioSent)
    }

    private func stopRequestedBroadcast() {
        deliveryStopped = true
        active = false
        stopWatchdog()
        sendBroadcastEnd { [weak self] in
            guard let self else { return }
            self.disconnect()
            self.report(.ended)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.finishBroadcastWithError(NSError(domain: RPRecordingErrorDomain,
                                                        code: RPRecordingErrorCode.userDeclined.rawValue,
                                                        userInfo: [NSLocalizedDescriptionKey: "Screen sharing stopped."]))
            }
        }
    }

    private func sendBroadcastEnd(completion: @escaping () -> Void) {
        if let pending = broadcastEndAction {
            broadcastEndAction = {
                pending()
                completion()
            }
            return
        }
        guard ready, (peer?.screenProtocolVersion ?? 1) >= 3, let link else {
            completion()
            return
        }
        broadcastEndAction = completion
        let id = connectionID
        link.send(content: Data([0, 0, 0, 0, 4]), completion: .contentProcessed { [weak self] error in
            guard let self, self.connectionID == id, error != nil else { return }
            self.completeBroadcastEnd()
        })
        queue.asyncAfter(deadline: .now() + .milliseconds(350)) { [weak self] in
            guard let self, self.connectionID == id else { return }
            self.completeBroadcastEnd()
        }
    }

    private func completeBroadcastEnd() {
        let action = broadcastEndAction
        broadcastEndAction = nil
        action?()
    }

    private func fail(_ message: String) {
        guard active else { return }
        active = false
        failed = true
        stopWatchdog()
        disconnect()
        report(.failed, message: message)
        // A ReplayKit finish callback may call back into our queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.finishBroadcastWithError(NSError(domain: "Porthole Broadcast", code: 1,
                                                    userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }

    private func refreshPreferences() {
        let now = DispatchTime.now()
        if let previous = preferencesCheckedAt, now < previous + .milliseconds(250) { return }
        preferencesCheckedAt = now
        let enabled = TrustedPeerStore.broadcastAudioEnabled()
        if sendAppAudio && !enabled { audio = BroadcastAudio() }
        sendAppAudio = enabled
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        if type == .audioApp || type == .video { refreshPreferences() }
        if type == .audioApp {
            if sendAppAudio { forwardAudio(sampleBuffer) }
            return
        }
        guard type == .video, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(timestamp)
        guard seconds.isFinite else { return }
        if let lastTimestamp, seconds >= lastTimestamp, seconds - lastTimestamp < minInterval { return }

        let turned = Self.orientation(sampleBuffer, image: image)
        let orientation = turned.pixels
        let orientationChanged = lastOrientation != orientation
        let timestampDiscontinuity = lastTimestamp.map { seconds < $0 } == true
        guard let ticket = queue.sync(execute: {
            reserveFrame(forceKey: orientationChanged || timestampDiscontinuity, ptsNs: Self.nanoseconds(timestamp),
                         turn: Self.turnMessage(turned, image: image))
        }) else { return }
        lastTimestamp = seconds
        lastOrientation = orientation

        guard let source = makeSource(image, orientation: orientation) else {
            loseFrame(ticket)
            return
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let newSession = session == nil || timestampDiscontinuity || width != sessionWidth || height != sessionHeight
        if newSession { makeSession(width: width, height: height) }
        guard let session else {
            loseFrame(ticket)
            return
        }

        let force = ticket.forceKey || newSession
        let properties: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: source, presentationTimeStamp: timestamp,
                                                     duration: .invalid, frameProperties: properties,
                                                     infoFlagsOut: &flags) { [weak self] result, flags, sample in
            guard let self else { return }
            guard result == noErr, !flags.contains(.frameDropped), let sample, let encoded = Self.annexB(sample) else {
                self.loseFrame(ticket)
                return
            }
            self.queue.async { self.send(encoded.bytes, keyframe: encoded.keyframe, ticket: ticket) }
        }
        if status != noErr || flags.contains(.frameDropped) { loseFrame(ticket) }
    }

    private func reserveFrame(forceKey: Bool, ptsNs: UInt64, turn: Data) -> FrameTicket? {
        // Keep ACKs in flight concurrently, but serialize compression output so
        // asynchronously delivered callbacks cannot reorder H.264 frames.
        guard active, ready, !paused, encoding.isEmpty,
              awaitingACK.lazy.filter(\.video).count < maxOutstanding else { return nil }
        let now = DispatchTime.now()
        let force = forceKey || needKey || lastKeyframeSent.map { now >= $0 + .milliseconds(1200) } == true
        if force { needKey = true }
        let ticket = FrameTicket(connectionID: connectionID, forceKey: force, ptsNs: ptsNs, turn: turn)
        encoding[ticket.id] = .now()
        return ticket
    }

    private func loseFrame(_ ticket: FrameTicket) {
        queue.async {
            guard self.connectionID == ticket.connectionID,
                  self.encoding.removeValue(forKey: ticket.id) != nil else { return }
            self.needKey = true
            self.lostFrames += 1
        }
    }

    private func send(_ bytes: Data, keyframe: Bool, ticket: FrameTicket) {
        guard active, ready, !paused, ticket.connectionID == connectionID,
              encoding.removeValue(forKey: ticket.id) != nil, let link else { return }
        guard !bytes.isEmpty, bytes.count <= Self.maxFrameBytes, (!needKey && !ticket.forceKey) || keyframe else {
            needKey = true
            lostFrames += 1
            return
        }
        lostFrames = 0
        if keyframe {
            needKey = false
            lastKeyframeSent = .now()
        }
        // The PC turns its pointer positions back with this: the iPhone places
        // an absolute pointer on its screen as mounted, not as turned.
        if (peer?.screenProtocolVersion ?? 1) >= 4, sentTurn != ticket.turn {
            sentTurn = ticket.turn
            sendPacket(ticket.turn, type: 5, ptsNs: ticket.ptsNs, link: link, id: ticket.connectionID)
        }
        sendPacket(bytes, type: keyframe ? 2 : 1, ptsNs: ticket.ptsNs, link: link, id: ticket.connectionID)
    }

    private func availableAudioPackets(now: DispatchTime) -> Int {
        guard active, ready, !paused, (peer?.screenProtocolVersion ?? 1) >= 2,
              lastAcknowledgedFrame != nil else { return 0 }
        // A still screen may have no new frames. Only a pending video frame
        // that has fallen behind should interrupt otherwise continuous audio.
        if encoding.values.contains(where: { now >= $0 + videoBacklogLimit }) ||
            awaitingACK.contains(where: { $0.video && now >= $0.sentAt + videoBacklogLimit }) {
            return 0
        }
        return 4 - awaitingACK.lazy.filter({ !$0.video }).count
    }

    private func forwardAudio(_ sample: CMSampleBuffer) {
        let id: UUID? = queue.sync {
            availableAudioPackets(now: .now()) > 0 ? connectionID : nil
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let id, timestamp.isNumeric, let bytes = audio.encode(sample) else { return }
        let ptsNs = Self.nanoseconds(timestamp)
        queue.sync {
            let available = availableAudioPackets(now: .now())
            guard available > 0, id == connectionID, let link else { return }
            for start in stride(from: 0, to: bytes.count, by: 8192).prefix(available) {
                let part = bytes.subdata(in: start..<min(start + 8192, bytes.count))
                let packetPts = ptsNs + UInt64(start / 4) * 1_000_000_000 / 44_100
                sendPacket(part, type: 3, ptsNs: packetPts, link: link, id: id,
                           hasAudioSignal: BroadcastAudio.containsSignal(part))
            }
        }
    }

    private func sendPacket(_ bytes: Data, type: UInt8, ptsNs: UInt64, link: NWConnection, id: UUID,
                            hasAudioSignal: Bool = false) {
        let useTimestamps = (peer?.screenProtocolVersion ?? 1) >= 3
        var frame = Data(capacity: bytes.count + (useTimestamps ? 13 : 5))
        let length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(type)
        if useTimestamps {
            let wirePts = ptsNs.bigEndian
            withUnsafeBytes(of: wirePts) { frame.append(contentsOf: $0) }
        }
        frame.append(bytes)
        awaitingACK.append(SentPacket(sentAt: .now(), video: type == 1 || type == 2,
                                      hasAudioSignal: hasAudioSignal))
        link.send(content: frame, completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link, self.link === link, self.connectionID == id,
                  error != nil else { return }
            self.retry("Could not send the broadcast to the paired PC.")
        })
    }

    private static func nanoseconds(_ timestamp: CMTime) -> UInt64 {
        let time = CMTimeConvertScale(timestamp, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
        return UInt64(max(1, time.value))
    }

    /// How to turn this frame upright (`pixels`), and how the phone itself is
    /// turned (`pointer`). They differ when iOS already supplies the screen
    /// turned: the picture then needs no turn, but the phone still places an
    /// absolute pointer on its screen as mounted.
    ///
    /// ReplayKit's `RPVideoSampleOrientationKey` names the opposite quarter-turn
    /// from Core Image: WebRTC's ReplayKit capturer (react-native-webrtc,
    /// used for Jitsi screen sharing) turns `.left` 90° clockwise and `.right`
    /// 270°, while `CIImage.oriented(.left)` turns 90° counterclockwise. Passing
    /// the tag straight to Core Image left both landscape directions upside down.
    private static func orientation(_ sample: CMSampleBuffer, image: CVImageBuffer)
        -> (pixels: CGImagePropertyOrientation, pointer: CGImagePropertyOrientation, tag: UInt32) {
        let key = kCGImagePropertyOrientation
        let sampleOrientation = CMGetAttachment(sample, key: key, attachmentModeOut: nil) as? NSNumber
        let pixelOrientation = CVBufferCopyAttachment(image, key, nil) as? NSNumber
        let fromSample = sampleOrientation.flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) }
        let fromImage = pixelOrientation.flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) }
        if let explicit = fromSample ?? fromImage { return (explicit, explicit, explicit.rawValue) }
        let tagValue = (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString,
                                        attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 0
        let replayKit = CGImagePropertyOrientation(rawValue: tagValue) ?? .up
        let turned: CGImagePropertyOrientation
        switch replayKit {
        case .left: turned = .right
        case .right: turned = .left
        case .leftMirrored: turned = .rightMirrored
        case .rightMirrored: turned = .leftMirrored
        default: turned = replayKit
        }
        let quarterTurn = turned != replayKit
        // Pixels that already have the landscape axes need no quarter-turn.
        let pixels: CGImagePropertyOrientation =
            quarterTurn && CVPixelBufferGetWidth(image) > CVPixelBufferGetHeight(image) ? .up : turned
        return (pixels, turned, tagValue)
    }

    private static func turnMessage(_ turned: (pixels: CGImagePropertyOrientation, pointer: CGImagePropertyOrientation, tag: UInt32),
                                    image: CVImageBuffer) -> Data {
        let width = UInt16(clamping: CVPixelBufferGetWidth(image))
        let height = UInt16(clamping: CVPixelBufferGetHeight(image))
        return Data([UInt8(truncatingIfNeeded: turned.pointer.rawValue), UInt8(truncatingIfNeeded: turned.tag),
                     UInt8(truncatingIfNeeded: turned.pixels.rawValue),
                     UInt8(width >> 8), UInt8(width & 0xff), UInt8(height >> 8), UInt8(height & 0xff)])
    }

    private func makeSession(width: Int, height: Int) {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = makeEncoder(width: width, height: height, lowLatency: true)
            ?? makeEncoder(width: width, height: height, lowLatency: false)
        sessionWidth = width
        sessionHeight = height
    }

    private func makeEncoder(width: Int, height: Int, lowLatency: Bool) -> VTCompressionSession? {
        var created: VTCompressionSession?
        let specification = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true] as CFDictionary
            : nil
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &created)
        guard status == noErr, let made = created else { return nil }
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                             value: kCFBooleanTrue)
        if !lowLatency {
            VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_Baseline_AutoLevel)
        }
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        // Keep the average bitrate while giving scene changes and keyframes
        // room to use more than a single frame's worth of bits.
        let peakWindow = 0.25
        let peakBytes = Int(Double(bitrate) * 2 / 8 * peakWindow)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: peakBytes), NSNumber(value: peakWindow)] as CFArray)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: frameRate))
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 2))
        guard VTCompressionSessionPrepareToEncodeFrames(made) == noErr else {
            VTCompressionSessionInvalidate(made)
            return nil
        }
        return made
    }

    /// Longer side at most `longEdge`, both sides even, so the PC draws the same size it
    /// already handles for AirPlay.
    private static func fit(width: Int, height: Int, longEdge: Int) -> (w: Int, h: Int) {
        let long = max(width, height)
        if long <= longEdge { return (max(2, width & ~1), max(2, height & ~1)) }
        if width >= height {
            let w = longEdge & ~1
            let h = max(2, ((height * w + width / 2) / width) & ~1)
            return (w, h)
        }
        let h = longEdge & ~1
        let w = max(2, ((width * h + height / 2) / height) & ~1)
        return (w, h)
    }

    private func makeSource(_ image: CVImageBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let inputWidth = CVPixelBufferGetWidth(image)
        let inputHeight = CVPixelBufferGetHeight(image)
        guard inputWidth >= 2, inputHeight >= 2 else { return nil }
        if orientation != .up {
            let rotated = CIImage(cvPixelBuffer: image, options: [.applyOrientationProperty: false]).oriented(orientation)
            let bounds = rotated.extent
            let size = Self.fit(width: Int(bounds.width), height: Int(bounds.height), longEdge: longEdge)
            guard let target = allocate(size, format: kCVPixelFormatType_32BGRA) else { return nil }
            let normalized = rotated.transformed(by: .init(translationX: -bounds.minX, y: -bounds.minY))
            let scaled = normalized.transformed(by: .init(scaleX: CGFloat(size.w) / bounds.width,
                                                          y: CGFloat(size.h) / bounds.height))
            imageContext.render(scaled, to: target, bounds: CGRect(x: 0, y: 0, width: size.w, height: size.h),
                                colorSpace: CGColorSpaceCreateDeviceRGB())
            return target
        }
        let size = Self.fit(width: inputWidth, height: inputHeight, longEdge: longEdge)
        if size.w == inputWidth, size.h == inputHeight { return image }
        if transfer == nil {
            var made: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &made) == noErr else { return nil }
            transfer = made
        }
        guard let transfer, let target = allocate(size, format: CVPixelBufferGetPixelFormatType(image)),
              VTPixelTransferSessionTransferImage(transfer, from: image, to: target) == noErr else { return nil }
        return target
    }

    private func allocate(_ size: (w: Int, h: Int), format: OSType) -> CVPixelBuffer? {
        if pool == nil || poolWidth != size.w || poolHeight != size.h || poolFormat != format {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: size.w,
                kCVPixelBufferHeightKey: size.h,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess else { return nil }
            pool = created
            poolWidth = size.w
            poolHeight = size.h
            poolFormat = format
        }
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: maxOutstanding + 1] as CFDictionary
        var result: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &result) == kCVReturnSuccess else { return nil }
        return result
    }

    private static func annexB(_ sample: CMSampleBuffer) -> (bytes: Data, keyframe: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= maxFrameBytes else { return nil }
        var parameterCount = 0
        var headerWidth: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                                parameterSetPointerOut: nil,
                                                                parameterSetSizeOut: nil,
                                                                parameterSetCountOut: &parameterCount,
                                                                nalUnitHeaderLengthOut: &headerWidth) == noErr,
              [1, 2, 4].contains(headerWidth), (2...32).contains(parameterCount) else { return nil }

        var input = Data(count: length)
        let copied = input.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let base = destination.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return nil }

        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first {
            keyframe = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }

        let start: [UInt8] = [0, 0, 0, 1]
        var output = Data(capacity: min(maxFrameBytes, length + 256))
        if keyframe {
            var hasSPS = false
            var hasPPS = false
            for index in 0..<parameterCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                        parameterSetPointerOut: &pointer,
                                                                        parameterSetSizeOut: &size,
                                                                        parameterSetCountOut: nil,
                                                                        nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer, size > 0, size <= maxFrameBytes - output.count - start.count else { return nil }
                hasSPS = hasSPS || pointer.pointee & 0x1f == 7
                hasPPS = hasPPS || pointer.pointee & 0x1f == 8
                output.append(contentsOf: start)
                output.append(pointer, count: size)
            }
            guard hasSPS, hasPPS else { return nil }
        }
        guard appendAnnexB(input, prefixWidth: Int(headerWidth), into: &output) else { return nil }
        return (output, keyframe)
    }

    /// AVCC permits one-, two-, and four-byte length fields. Convert complete units.
    private static func appendAnnexB(_ input: Data, prefixWidth: Int, into output: inout Data) -> Bool {
        guard [1, 2, 4].contains(prefixWidth), input.count <= maxFrameBytes else { return false }
        let start: [UInt8] = [0, 0, 0, 1]
        let payloadStart = output.count
        var offset = input.startIndex
        while offset < input.endIndex {
            guard prefixWidth <= input.endIndex - offset else { return false }
            var size = 0
            for byte in input[offset..<(offset + prefixWidth)] { size = (size << 8) | Int(byte) }
            offset += prefixWidth
            guard size > 0, size <= input.endIndex - offset,
                  size <= maxFrameBytes - output.count - start.count else { return false }
            output.append(contentsOf: start)
            output.append(contentsOf: input[offset..<(offset + size)])
            offset += size
        }
        return output.count > payloadStart
    }
}
