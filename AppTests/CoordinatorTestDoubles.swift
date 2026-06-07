import Foundation
@testable import SayItCore

/// 可控的假录音器：注入「停止时返回的样本」或「启动时抛错」，并记录调用次数。
/// 实现为 `actor`（与真实 `AudioRecorder` 一致），在不触碰麦克风硬件下走通录音相关分支。
actor FakeAudioRecorder: AudioRecording {
    enum StartBehavior: Sendable { case succeeds; case throwsDenied }

    private let samples: [Float]
    private let startBehavior: StartBehavior

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var recording = false

    /// 每会话重建的电平流持有器（镜像真实 `AudioRecorder`：每次 `start()` 换一对全新的
    /// single-consumer 流）。这样测试才能复现真实生命周期——编排层若仍在启动前一次性捕获旧流，
    /// 本会话 `start()` 重建后 `emitLevel` 的值就到不了消费者，断言失败。
    private nonisolated let levelStream = FakeLevelStreamHolder()

    /// 实时电平流：读取当前会话的流（须在 `start()` 之后读取才拿到本会话的新流）。
    nonisolated var levels: AsyncStream<Double> { levelStream.currentStream }

    init(samples: [Float] = [0.1, 0.2, 0.3], startBehavior: StartBehavior = .succeeds) {
        self.samples = samples
        self.startBehavior = startBehavior
    }

    func start() async throws {
        try await start(deviceUID: nil)
    }

    /// 与 `start()` 共用同一套录音逻辑（仅忽略设备选择，假实现不接真实硬件）。
    /// 让本 fake 重新满足 `AudioRecording`（协议要求 `start(deviceUID:)`）。
    func start(deviceUID: String?) async throws {
        startCount += 1
        switch startBehavior {
        case .succeeds:
            recording = true
            // 镜像真实录音器：每次 start 重建本会话的电平流。
            levelStream.beginSession()
        case .throwsDenied:
            throw AudioRecordingError.microphonePermissionDenied
        }
    }

    /// 测试用：把一个归一化电平投递进当前会话的流（模拟真实 tap 的 yield）。
    nonisolated func emitLevel(_ level: Double) {
        levelStream.currentContinuation.yield(level)
    }

    @discardableResult
    func stop() async throws -> [Float] {
        stopCount += 1
        guard recording else { throw AudioRecordingError.notRecording }
        recording = false
        levelStream.endSession()
        return samples
    }

    var isRecording: Bool { recording }
}

/// `FakeAudioRecorder` 的「每会话可重建」电平流持有器（镜像 `AudioRecorder.LevelStreamHolder`）。
/// 用锁守护一对 `AsyncStream` + `Continuation`，供 `nonisolated` 上下文安全读写。
private final class FakeLevelStreamHolder: @unchecked Sendable {
    private struct Pair {
        var stream: AsyncStream<Double>
        var continuation: AsyncStream<Double>.Continuation
    }

    private let lock = NSLock()
    private var pair: Pair

    init() { pair = Self.makePair() }

    private static func makePair() -> Pair {
        var continuation: AsyncStream<Double>.Continuation!
        let stream = AsyncStream<Double>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        return Pair(stream: stream, continuation: continuation)
    }

    var currentStream: AsyncStream<Double> {
        lock.lock(); defer { lock.unlock() }; return pair.stream
    }

    var currentContinuation: AsyncStream<Double>.Continuation {
        lock.lock(); defer { lock.unlock() }; return pair.continuation
    }

    /// 开始新会话：结束旧流并换上一对全新的流。
    func beginSession() {
        lock.lock(); defer { lock.unlock() }
        pair.continuation.finish()
        pair = Self.makePair()
    }

    /// 结束当前会话：归零后结束流。
    func endSession() {
        lock.lock(); defer { lock.unlock() }
        pair.continuation.yield(0)
        pair.continuation.finish()
    }
}

/// 可控的假注入器：记录被注入的文本，并按预设返回成功/失败。
final class FakeTextInjector: TextInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private let result: InjectionResult
    private var _injected: [String] = []

    init(result: InjectionResult = .success(method: .pasteboard)) {
        self.result = result
    }

    @MainActor
    func inject(_ text: String) -> InjectionResult {
        lock.lock(); _injected.append(text); lock.unlock()
        return result
    }

    var injectedTexts: [String] {
        lock.lock(); defer { lock.unlock() }; return _injected
    }
}
