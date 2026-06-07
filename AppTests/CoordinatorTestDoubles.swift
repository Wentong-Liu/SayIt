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

    /// 电平流（测试里不投递值，仅满足协议；coordinator 的转发任务会静默等待）。
    nonisolated let levels: AsyncStream<Double>
    private nonisolated let levelContinuation: AsyncStream<Double>.Continuation

    init(samples: [Float] = [0.1, 0.2, 0.3], startBehavior: StartBehavior = .succeeds) {
        self.samples = samples
        self.startBehavior = startBehavior
        var cont: AsyncStream<Double>.Continuation!
        self.levels = AsyncStream { cont = $0 }
        self.levelContinuation = cont
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
        case .throwsDenied:
            throw AudioRecordingError.microphonePermissionDenied
        }
    }

    @discardableResult
    func stop() async throws -> [Float] {
        stopCount += 1
        guard recording else { throw AudioRecordingError.notRecording }
        recording = false
        return samples
    }

    var isRecording: Bool { recording }
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
