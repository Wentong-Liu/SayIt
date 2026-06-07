import AVFoundation
import XCTest
@testable import SayItCore

final class AudioFormatTests: XCTestCase {
    func testTargetFormatConstants() {
        XCTAssertEqual(AudioFormat.sampleRate, 16_000)
        XCTAssertEqual(AudioFormat.channelCount, 1)
        XCTAssertEqual(AudioFormat.bytesPerSample, 4)
    }
}

final class FloatSampleAccumulatorTests: XCTestCase {
    /// 造一个 Float32 单声道 PCM 缓冲，channel-0 填入给定样本。
    private func makeBuffer(_ samples: [Float], sampleRate: Double = AudioFormat.sampleRate) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (i, value) in samples.enumerated() { channel[i] = value }
        return buffer
    }

    func testInitialIsEmpty() {
        let acc = FloatSampleAccumulator()
        XCTAssertEqual(acc.count, 0)
        XCTAssertTrue(acc.samples.isEmpty)
        XCTAssertEqual(acc.durationSeconds, 0)
    }

    func testAppendBufferAccumulatesChannelZero() {
        var acc = FloatSampleAccumulator()
        let added = acc.append(makeBuffer([0.1, -0.2, 0.3]))
        XCTAssertEqual(added, 3)
        XCTAssertEqual(acc.count, 3)
        XCTAssertEqual(acc.samples, [0.1, -0.2, 0.3])
    }

    func testAppendMultipleBuffersConcatenatesInOrder() {
        var acc = FloatSampleAccumulator()
        acc.append(makeBuffer([1, 2]))
        acc.append(makeBuffer([3, 4, 5]))
        XCTAssertEqual(acc.samples, [1, 2, 3, 4, 5])
        XCTAssertEqual(acc.count, 5)
    }

    func testAppendEmptyBufferIsIgnored() {
        var acc = FloatSampleAccumulator()
        let added = acc.append(makeBuffer([]))
        XCTAssertEqual(added, 0)
        XCTAssertEqual(acc.count, 0)
    }

    func testAppendNonFloat32BufferIsIgnored() {
        // Int16 缓冲（非 Float32）应被忽略。
        let int16Format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: 4)!
        buffer.frameLength = 4
        var acc = FloatSampleAccumulator()
        let added = acc.append(buffer)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(acc.count, 0)
    }

    func testAppendContentsOfRawSamples() {
        var acc = FloatSampleAccumulator()
        acc.append(contentsOf: [0.5, 0.6])
        acc.append(contentsOf: [0.7])
        XCTAssertEqual(acc.samples, [0.5, 0.6, 0.7])
    }

    func testDurationSecondsUsesTargetSampleRate() {
        var acc = FloatSampleAccumulator()
        // 16000 个样本应为 1 秒。
        acc.append(contentsOf: [Float](repeating: 0, count: 16_000))
        XCTAssertEqual(acc.durationSeconds, 1.0, accuracy: 1e-9)
    }

    func testResetClearsSamples() {
        var acc = FloatSampleAccumulator()
        acc.append(contentsOf: [1, 2, 3])
        acc.reset()
        XCTAssertEqual(acc.count, 0)
        XCTAssertTrue(acc.samples.isEmpty)
    }

    func testDrainReturnsAndClears() {
        var acc = FloatSampleAccumulator()
        acc.append(contentsOf: [9, 8, 7])
        let drained = acc.drain()
        XCTAssertEqual(drained, [9, 8, 7])
        XCTAssertEqual(acc.count, 0)
        XCTAssertTrue(acc.samples.isEmpty)
    }
}

final class MicrophoneAuthorizationTests: XCTestCase {
    func testMapsAVAuthorizationStatus() {
        XCTAssertEqual(MicrophoneAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(MicrophoneAuthorization(.authorized), .authorized)
        XCTAssertEqual(MicrophoneAuthorization(.denied), .denied)
        XCTAssertEqual(MicrophoneAuthorization(.restricted), .restricted)
    }
}

final class AudioRecorderStateTests: XCTestCase {
    func testStopWithoutStartThrowsNotRecording() async {
        let recorder = AudioRecorder()
        do {
            _ = try await recorder.stop()
            XCTFail("应抛出 notRecording")
        } catch let error as AudioRecordingError {
            XCTAssertEqual(error.description, AudioRecordingError.notRecording.description)
        } catch {
            XCTFail("意外错误类型: \(error)")
        }
    }

    func testIsRecordingFalseInitially() async {
        let recorder = AudioRecorder()
        let recording = await recorder.isRecording
        XCTAssertFalse(recording)
    }
}

final class AudioLevelTests: XCTestCase {
    func testSilenceIsZero() {
        XCTAssertEqual(AudioRecorder.normalizedLevel([Float](repeating: 0, count: 256)), 0, accuracy: 1e-9)
    }

    func testEmptyIsZero() {
        XCTAssertEqual(AudioRecorder.normalizedLevel([]), 0, accuracy: 1e-9)
    }

    func testFullScaleIsOne() {
        // RMS = 1（满量程）→ 0 dBFS → 归一化为 1。
        XCTAssertEqual(AudioRecorder.normalizedLevel([Float](repeating: 1, count: 128)), 1, accuracy: 1e-6)
    }

    func testLevelIsInUnitRangeAndMonotonic() {
        let quiet = AudioRecorder.normalizedLevel([Float](repeating: 0.01, count: 128))
        let loud = AudioRecorder.normalizedLevel([Float](repeating: 0.5, count: 128))
        XCTAssertGreaterThanOrEqual(quiet, 0)
        XCTAssertLessThanOrEqual(loud, 1)
        XCTAssertGreaterThan(loud, quiet, "更大幅度应得到更高电平")
    }
}
