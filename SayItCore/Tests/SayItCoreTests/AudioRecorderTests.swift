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
    /// Builds a Float32 mono PCM buffer, filling channel 0 with the given samples.
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
        // An Int16 buffer (not Float32) should be ignored.
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
        // 16000 samples should be 1 second.
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
            XCTFail("should throw notRecording")
        } catch let error as AudioRecordingError {
            XCTAssertEqual(error.description, AudioRecordingError.notRecording.description)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testIsRecordingFalseInitially() async {
        let recorder = AudioRecorder()
        let recording = await recorder.isRecording
        XCTAssertFalse(recording)
    }
}

/// A regression test that reproduces and locks down "the mic test has no green bars the second time".
///
/// Root cause: the old implementation of `AudioRecorder.levels` was a "single shared for the whole lifecycle" `AsyncStream`.
/// `AsyncStream` is a single-consumer stream -- once its sole consuming iteration is cancelled/ended (`MicTestViewModel`
/// triggers it via `levelTask?.cancel()` in `stopTesting()`), the whole stream finishes permanently;
/// the second test's new task reads the same already-finished stream and immediately receives end, with zero level arriving -- manifesting as
/// "green bars on the first test, no green bars on the retest".
///
/// Fix: each `start()` session rebuilds a brand-new pair of stream + continuation; the consumer reads `recorder.levels` after `start()`
/// (both MicTest/HUD do so), getting this session's new stream.
final class AudioLevelStreamReconsumableTests: XCTestCase {
    /// Consumes on the given stream until receiving `count` **non-zero** levels or timing out; returns the number of non-zero ones received.
    /// Simulates HUD/MicTest: `for await value in recorder.levels`.
    private func consumeNonZero(
        _ stream: AsyncStream<Double>,
        upTo count: Int,
        timeout: TimeInterval
    ) async -> Int {
        let task = Task { () -> Int in
            var received = 0
            for await value in stream {
                if value > 0 { received += 1 }
                if received >= count { break }
            }
            return received
        }
        // Timeout fallback: avoid hanging forever when the second session gets no values (i.e. the old bug's manifestation).
        let timeoutTask = Task { () -> Int in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            task.cancel()
            return 0
        }
        let result = await task.value
        timeoutTask.cancel()
        return result
    }

    /// Core regression: two sequential "session + consume", the second must still be able to get levels.
    ///
    /// Replicates the real flow:
    ///  Session 1: `start()`(beginSession) -> read `levels` -> for-await consume -> the task is cancelled (stopTesting) -> `stop()`(endSession)
    ///  Session 2: `start()`(beginSession) -> **re-read** `levels` -> for-await consume -> assert there are still non-zero levels
    /// Under the old implementation session 2 would get 0 non-zero values (the stream is permanently finished) -- this test is exactly for reproducing and preventing regression.
    func testLevelsAreReconsumableAcrossSessions() async {
        let recorder = AudioRecorder()

        // -- Session 1 --
        recorder.beginLevelSessionForTesting()        // equivalent to beginSession() inside start()
        let session1 = recorder.levels                // the consumer reads levels after start()
        // A "tap" that keeps producing levels until cancelled.
        let tap1 = Task {
            while !Task.isCancelled {
                recorder.emitLevelForTesting(0.5)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let got1 = await consumeNonZero(session1, upTo: 3, timeout: 2.0)
        tap1.cancel()
        XCTAssertGreaterThanOrEqual(got1, 3, "session 1 should be able to get levels (green bars on the first test)")
        // Simulate stopTesting(): the consuming task has ended (the for-await above has broken), then endSession().
        recorder.endLevelSessionForTesting()          // equivalent to endSession() inside stop()

        // -- Session 2 -- (key: reuse the same recorder; the old implementation would get 0 here)
        recorder.beginLevelSessionForTesting()        // the second start()
        let session2 = recorder.levels                // re-read levels: must be a brand-new stream
        let tap2 = Task {
            while !Task.isCancelled {
                recorder.emitLevelForTesting(0.7)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let got2 = await consumeNonZero(session2, upTo: 3, timeout: 2.0)
        tap2.cancel()
        XCTAssertGreaterThanOrEqual(
            got2, 3,
            "session 2 should still be able to get levels (the retest must have green bars) -- the old implementation returned 0 here, which is this bug"
        )
    }

    /// Even if the previous session's consuming task ended via "cancel" rather than a natural break (which is exactly stopTesting's real path),
    /// the next session should still be able to get levels. This is the old implementation's most fatal failure path.
    func testLevelsReconsumableAfterConsumerTaskCancelled() async {
        let recorder = AudioRecorder()

        // Session 1: the consuming task is explicitly cancelled (simulating stopTesting's levelTask?.cancel()).
        recorder.beginLevelSessionForTesting()
        let session1 = recorder.levels
        let consumer1 = Task { () -> Int in
            var n = 0
            for await value in session1 where value > 0 {
                n += 1
            }
            return n
        }
        let tap1 = Task {
            while !Task.isCancelled {
                recorder.emitLevelForTesting(0.5)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        consumer1.cancel()                            // key: cancel the consuming task (the old bug's trigger point)
        tap1.cancel()
        _ = await consumer1.value
        recorder.endLevelSessionForTesting()

        // Session 2: read the brand-new stream, must still be able to get non-zero levels.
        recorder.beginLevelSessionForTesting()
        let session2 = recorder.levels
        let tap2 = Task {
            while !Task.isCancelled {
                recorder.emitLevelForTesting(0.7)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let got2 = await consumeNonZero(session2, upTo: 3, timeout: 2.0)
        tap2.cancel()
        XCTAssertGreaterThanOrEqual(
            got2, 3,
            "after the previous consuming task is cancelled, the retest should still be able to get levels -- the old implementation returned 0 here"
        )
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
        // RMS = 1 (full scale) -> 0 dBFS -> normalized to 1.
        XCTAssertEqual(AudioRecorder.normalizedLevel([Float](repeating: 1, count: 128)), 1, accuracy: 1e-6)
    }

    func testLevelIsInUnitRangeAndMonotonic() {
        let quiet = AudioRecorder.normalizedLevel([Float](repeating: 0.01, count: 128))
        let loud = AudioRecorder.normalizedLevel([Float](repeating: 0.5, count: 128))
        XCTAssertGreaterThanOrEqual(quiet, 0)
        XCTAssertLessThanOrEqual(loud, 1)
        XCTAssertGreaterThan(loud, quiet, "a larger amplitude should yield a higher level")
    }
}
