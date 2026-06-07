import AVFoundation
import Foundation

/// During recording, accumulates segment-by-segment (already converted to target format) PCM buffers into a contiguous `[Float]`.
///
/// This is the unit-testable pure logic inside AudioRecorder: it never touches hardware, only handles
/// "extracting channel-0 Float32 samples from an AVAudioPCMBuffer and appending them to an internal array".
/// Real capture (AVAudioEngine tap) just keeps feeding buffers in; this class does not care about the source.
///
/// Not thread-safe: the caller (AudioRecorder) must ensure serial access itself (in practice guaranteed by the audio tap's
/// single dispatch order + actor isolation).
public struct FloatSampleAccumulator {
    /// Accumulated samples.
    public private(set) var samples: [Float]

    public init() {
        self.samples = []
    }

    /// Number of accumulated samples.
    public var count: Int { samples.count }

    /// Accumulated duration (seconds) estimated at the target sample rate.
    public var durationSeconds: Double {
        Double(samples.count) / AudioFormat.sampleRate
    }

    /// Clears the accumulated samples (called before reusing the same accumulator to start a new recording).
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Directly appends a ready segment of Float samples (already channel-0 samples in the target format).
    public mutating func append(contentsOf newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    /// Appends the channel-0 samples of one PCM Float32 buffer.
    ///
    /// Expects `buffer` to already be in Float32 format (`commonFormat == .pcmFormatFloat32`).
    /// Reads only channel 0 -- upstream should have already converted to mono; for multi-channel only the first channel is taken to avoid erroneous silent summing.
    /// If the buffer is not Float32, or has no floatChannelData, or frameLength is 0, it is ignored.
    /// Returns the number of samples actually appended this time.
    @discardableResult
    public mutating func append(_ buffer: AVAudioPCMBuffer) -> Int {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let channel0 = channelData[0]
        samples.append(contentsOf: UnsafeBufferPointer(start: channel0, count: frameCount))
        return frameCount
    }

    /// Takes the accumulated result and clears the internal buffer (one-shot consumption, for stop() to return).
    public mutating func drain() -> [Float] {
        let result = samples
        samples.removeAll(keepingCapacity: true)
        return result
    }
}
