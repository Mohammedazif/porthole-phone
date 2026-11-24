import AVFAudio
import CoreMedia
import Foundation

/// Converts ReplayKit application audio to PSCR 2 stereo PCM16LE.
final class BroadcastAudio {
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100,
                                             channels: 2, interleaved: true)!
    private var converter: AVAudioConverter?

    static func containsSignal(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
                let sample = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                if sample > 8 || sample < -8 { return true }
            }
            return false
        }
    }

    func encode(_ sample: CMSampleBuffer) -> Data? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: stream),
              (1...8192).contains(frames), (8000...192000).contains(format.sampleRate),
              let input = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * outputFormat.sampleRate / format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        input.frameLength = input.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(input.frameLength),
                                                          into: input.mutableAudioBufferList) == noErr else { return nil }
        if converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: outputFormat)
        }
        guard let converter else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = provided ? .noDataNow : .haveData
            if provided { return nil }
            provided = true
            return input
        }
        guard status != .error, output.frameLength > 0,
              let bytes = output.audioBufferList.pointee.mBuffers.mData else { return nil }
        return Data(bytes: bytes, count: Int(output.frameLength) * 4)
    }
}
