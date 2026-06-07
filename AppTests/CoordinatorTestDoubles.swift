import Foundation
@testable import SayItCore

/// A controllable fake recorder: injects "the samples returned on stop" or "an error thrown on start", and records the call counts.
/// Implemented as an `actor` (consistent with the real `AudioRecorder`), exercising recording-related branches without touching microphone hardware.
actor FakeAudioRecorder: AudioRecording {
    enum StartBehavior: Sendable { case succeeds; case throwsDenied }

    private let samples: [Float]
    private let startBehavior: StartBehavior

    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// The device UID received by the most recent `start(deviceUID:)` (for tests to assert that end-to-end dictation carried the persisted microphone selection).
    private(set) var lastStartDeviceUID: String?
    private var recording = false

    /// The per-session rebuilt level stream holder (mirroring the real `AudioRecorder`: each `start()` swaps in a brand-new pair of
    /// single-consumer streams). This lets the test reproduce the real lifecycle -- if the orchestration layer still captures the old stream once before start,
    /// the value of `emitLevel` after this session's `start()` rebuild would not reach the consumer, and the assertion would fail.
    private nonisolated let levelStream = FakeLevelStreamHolder()

    /// The live level stream: reads the current session's stream (must be read after `start()` to get this session's new stream).
    nonisolated var levels: AsyncStream<Double> { levelStream.currentStream }

    init(samples: [Float] = [0.1, 0.2, 0.3], startBehavior: StartBehavior = .succeeds) {
        self.samples = samples
        self.startBehavior = startBehavior
    }

    func start() async throws {
        try await start(deviceUID: nil)
    }

    /// Shares the same recording logic as `start()` (only ignoring the device selection, the fake implementation does not connect to real hardware).
    /// Lets this fake re-satisfy `AudioRecording` (the protocol requires `start(deviceUID:)`).
    func start(deviceUID: String?) async throws {
        startCount += 1
        lastStartDeviceUID = deviceUID
        switch startBehavior {
        case .succeeds:
            recording = true
            // Mirror the real recorder: each start rebuilds this session's level stream.
            levelStream.beginSession()
        case .throwsDenied:
            throw AudioRecordingError.microphonePermissionDenied
        }
    }

    /// For testing: deliver a normalized level into the current session's stream (simulating a real tap's yield).
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

/// The "per-session rebuildable" level stream holder of `FakeAudioRecorder` (mirroring `AudioRecorder.LevelStreamHolder`).
/// Guards a pair of `AsyncStream` + `Continuation` with a lock, for safe read/write from a `nonisolated` context.
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

    /// Start a new session: end the old stream and swap in a brand-new pair of streams.
    func beginSession() {
        lock.lock(); defer { lock.unlock() }
        pair.continuation.finish()
        pair = Self.makePair()
    }

    /// End the current session: zero out then end the stream.
    func endSession() {
        lock.lock(); defer { lock.unlock() }
        pair.continuation.yield(0)
        pair.continuation.finish()
    }
}

/// A controllable fake injector: records the injected text and returns success/failure per the preset.
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
