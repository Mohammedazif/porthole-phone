import AVFAudio
import CoreMedia
import Foundation

/// Converts ReplayKit application audio to PSCR 2 stereo PCM16LE.
final class BroadcastAudio {
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100,
                                             channels: 2, interleaved: true)!
    private var converter: AVAudioConverter?

    func encode(_ sample: CMSampleBuffer) -> Data? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: stream),
              (1...2_048).contains(CMSampleBufferGetNumSamples(sample)),
              let input = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2_048) else { return nil }
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
