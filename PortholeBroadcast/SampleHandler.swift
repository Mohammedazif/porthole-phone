import Network
import ReplayKit
import VideoToolbox

/// Sends this iPhone's own screen to Porthole on the PC. Unlike AirPlay mirroring,
/// a broadcast is always what the phone shows: Photos keeps its bars, and share
/// sheets and alerts appear. Frames are encoded on the hardware H.264 encoder and
/// streamed as Annex-B after a "PSCR 1" line, each frame as a 4-byte big-endian
/// length, a type byte (1 video, 2 keyframe) and the bytes.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "porthole.broadcast")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var link: NWConnection?
    private var ready = false
    /// Frames sent that the PC has not yet answered with its one-byte 'A'.
    private var unacked = 0
    private var needKey = true
    private var session: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var lastFrame = CMTime.invalid
    private var stopped = false

    /// About 30 frames a second. A frame is skipped, not queued, while this many are
    /// still unanswered, so a slow moment on Wi-Fi drops frames instead of adding lag.
    private let minInterval = 1.0 / 31.0
    private let maxUnacked = 2

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        queue.async { self.browse() }
    }

    override func broadcastFinished() {
        lock.lock()
        stopped = true
        ready = false
        lock.unlock()
        queue.sync {
            browser?.cancel()
            browser = nil
            link?.cancel()
            link = nil
        }
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    // MARK: Finding and reaching Porthole

    private func browse() {
        browser?.cancel()
        let found = NWBrowser(for: .bonjour(type: "_porthole-screen._tcp", domain: nil), using: .tcp)
        found.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.link == nil, let first = results.first else { return }
            self.connect(to: first.endpoint)
        }
        found.start(queue: queue)
        browser = found
    }

    private func connect(to endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        // Porthole listens on IPv4, and only accepts the phone whose photo link it knows.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.link === connection else { return }
            switch state {
            case .ready:
                connection.send(content: Data("PSCR 1\n".utf8), completion: .contentProcessed { _ in })
                self.lock.lock()
                self.ready = true
                self.needKey = true
                self.unacked = 0
                self.lock.unlock()
                self.watch(connection)
            case .failed, .cancelled:
                self.dropLink()
            case .waiting:
                connection.cancel()
            default:
                break
            }
        }
        link = connection
        connection.start(queue: queue)
    }

    /// Porthole answers every frame with one byte; a finished receive means it closed.
    private func watch(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.unacked = max(0, self.unacked - data.count)
                self.lock.unlock()
            }
            if complete || error != nil {
                connection.cancel()
                self.dropLink()
                return
            }
            self.watch(connection)
        }
    }

    private func dropLink() {
        lock.lock()
        ready = false
        let finished = stopped
        lock.unlock()
        link = nil
        if finished { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.link == nil else { return }
            self.browse()
        }
    }

    // MARK: Frames

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lock.lock()
        let go = ready && unacked < maxUnacked
            && (!lastFrame.isValid || CMTimeGetSeconds(CMTimeSubtract(time, lastFrame)) >= minInterval)
        let key = needKey
        if go {
            lastFrame = time
            needKey = false
            unacked += 1 /* counted now: the encoder is asynchronous */
        }
        lock.unlock()
        guard go else { return }

        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        if session == nil || width != sessionWidth || height != sessionHeight {
            makeSession(width: width, height: height)
        }
        guard let session else {
            unsent()
            return
        }
        let properties: CFDictionary? = key
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: time,
                                        duration: .invalid, frameProperties: properties,
                                        infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            guard status == noErr, let sample, let encoded = Self.annexB(sample) else {
                self.unsent() /* dropped by the encoder: nothing for the PC to answer */
                return
            }
            self.send(encoded.0, keyframe: encoded.1)
        }
    }

    private func makeSession(width: Int, height: Int) {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &created)
        guard status == noErr, let made = created else { return }
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: 5_000_000))
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 2))
        VTCompressionSessionPrepareToEncodeFrames(made)
        session = made
        sessionWidth = width
        sessionHeight = height
        lock.lock()
        needKey = true
        lock.unlock()
    }

    private func send(_ bytes: Data, keyframe: Bool) {
        var frame = Data(capacity: bytes.count + 5)
        let length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(keyframe ? 2 : 1)
        frame.append(bytes)
        queue.async {
            guard let link = self.link else {
                self.unsent()
                return
            }
            link.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self, error != nil else { return }
                self.lock.lock()
                self.needKey = true
                self.lock.unlock()
            })
        }
    }

    private func unsent() {
        lock.lock()
        unacked = max(0, unacked - 1)
        lock.unlock()
    }

    /// Length-prefixed NAL units to start codes, with SPS and PPS before a keyframe.
    private static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var key = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first {
            key = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                               parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                      parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size,
                                                                      parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr,
                   let pointer {
                    out.append(contentsOf: start)
                    out.append(pointer, count: size)
                }
            }
        }
        var total = 0
        var base: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &total, dataPointerOut: &base) == noErr,
              let base else { return nil }
        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= total {
            let nal = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            if nal <= 0 || offset + nal > total { break }
            out.append(contentsOf: start)
            out.append(bytes + offset, count: nal)
            offset += nal
        }
        return out.isEmpty ? nil : (out, key)
    }
}
