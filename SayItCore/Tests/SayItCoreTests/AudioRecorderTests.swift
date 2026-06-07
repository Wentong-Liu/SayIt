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

/// 复现并锁定「mic 测试第二次没有绿条」的回归测试。
///
/// 根因：`AudioRecorder.levels` 旧实现是「整个生命周期单一共享」的 `AsyncStream`。
/// `AsyncStream` 是单消费者流——一旦其唯一消费迭代被取消/结束（`MicTestViewModel`
/// 在 `stopTesting()` 里 `levelTask?.cancel()` 即触发），整条流便永久 finish；
/// 第二次测试新建任务读取同一条已结束的流，立刻收到结束、零电平到达——表现为
/// 「首测有绿条、复测无绿条」。
///
/// 修复：每次 `start()` 会话重建一对全新的流 + continuation；消费者在 `start()`
/// 之后读取 `recorder.levels`（MicTest/HUD 均如此），拿到的是本会话的新流。
final class AudioLevelStreamReconsumableTests: XCTestCase {
    /// 在给定流上消费，直到收到 `count` 个 **非零** 电平或超时；返回收到的非零个数。
    /// 模拟 HUD/MicTest：`for await value in recorder.levels`。
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
        // 超时兜底：避免第二次会话拿不到值时永久挂起（即旧 bug 的表现）。
        let timeoutTask = Task { () -> Int in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            task.cancel()
            return 0
        }
        let result = await task.value
        timeoutTask.cancel()
        return result
    }

    /// 核心回归：两次顺序「会话 + 消费」，第二次必须仍能拿到电平。
    ///
    /// 复刻真实流程：
    ///  会话1：`start()`(beginSession) → 读 `levels` → for-await 消费 → 任务被取消（stopTesting）→ `stop()`(endSession)
    ///  会话2：`start()`(beginSession) → **重新读** `levels` → for-await 消费 → 断言仍有非零电平
    /// 旧实现下会话2 会拿到 0 个非零值（流已永久结束）——本测试即用来复现并防回归。
    func testLevelsAreReconsumableAcrossSessions() async {
        let recorder = AudioRecorder()

        // —— 会话 1 ——
        recorder.beginLevelSessionForTesting()        // 等价于 start() 内的 beginSession()
        let session1 = recorder.levels                // 消费者在 start() 之后读取 levels
        // 持续产电平的「tap」，直到被取消。
        let tap1 = Task {
            while !Task.isCancelled {
                recorder.emitLevelForTesting(0.5)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let got1 = await consumeNonZero(session1, upTo: 3, timeout: 2.0)
        tap1.cancel()
        XCTAssertGreaterThanOrEqual(got1, 3, "会话1 应能拿到电平（首测有绿条）")
        // 模拟 stopTesting()：消费任务已结束（上面 for-await 已 break），再 endSession()。
        recorder.endLevelSessionForTesting()          // 等价于 stop() 内的 endSession()

        // —— 会话 2 ——（关键：复用同一个 recorder，旧实现此处会拿到 0）
        recorder.beginLevelSessionForTesting()        // 第二次 start()
        let session2 = recorder.levels                // 重新读取 levels：必须是全新的流
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
            "会话2 仍应能拿到电平（复测必须有绿条）——旧实现此处为 0，即本 bug"
        )
    }

    /// 即便上一次会话的消费任务是被「取消」而非自然 break 结束（正是 stopTesting 的真实路径），
    /// 下一次会话仍应能拿到电平。这是旧实现最致命的失败路径。
    func testLevelsReconsumableAfterConsumerTaskCancelled() async {
        let recorder = AudioRecorder()

        // 会话1：消费任务被显式 cancel（模拟 stopTesting 的 levelTask?.cancel()）。
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
        consumer1.cancel()                            // 关键：取消消费任务（旧 bug 触发点）
        tap1.cancel()
        _ = await consumer1.value
        recorder.endLevelSessionForTesting()

        // 会话2：读取全新流，必须仍能拿到非零电平。
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
            "上次消费任务被取消后，复测仍应能拿到电平——旧实现此处为 0"
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
