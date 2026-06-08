import Foundation
@testable import SayItCore

/// A controllable fake recorder: injects "the samples returned on stop" or "an error thrown on start", and records the call counts.
/// Implemented as an `actor` (consistent with the real `AudioRecorder`), exercising recording-related branches without touching microphone hardware.
actor FakeAudioRecorder: AudioRecording {
    enum StartBehavior: Sendable { case succeeds; case throwsDenied }

    private let samples: [Float]
    private let startBehavior: StartBehavior
    /// Artificial delay applied at the START of `stop()`, before it flips `recording` to false. Mirrors the real `AudioRecorder.stop()`'s
    /// AVAudioEngine teardown taking time on the actor. Used to deterministically reproduce the "cancel's in-flight stop races a subsequent
    /// start" bug: while this delay is in flight the recorder is still `recording`, so a racing `start()` that does not await the pending stop
    /// would observe `recording == true`. Defaults to 0 (no delay) so existing tests are unaffected.
    private let stopDelay: Duration

    /// Optional manual gate: when armed via ``gateStop()``, `stop()` suspends after incrementing its count but BEFORE flipping `recording`
    /// to false, until ``releaseStop()`` is called. This deterministically pins the recorder in the "stop in flight, still recording" window
    /// so a test can drive a racing `start()` into it (the cancel-then-restart bug) with no reliance on scheduling luck.
    private var stopGate: CheckedContinuation<Void, Never>?
    private var stopGateArmed = false

    /// Optional manual gate: when armed via ``gateStart()``, `start()` suspends after incrementing its count but BEFORE flipping `recording`
    /// to true (and before rebuilding the level stream), until ``releaseStart()`` is called. This deterministically pins the recorder in the
    /// "start in flight, suspended" window so a test can land a `cancel()` mid-start (the startTask-resurrection bug) with no scheduling luck.
    private var startGate: CheckedContinuation<Void, Never>?
    private var startGateArmed = false

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

    init(samples: [Float] = [0.1, 0.2, 0.3],
         startBehavior: StartBehavior = .succeeds,
         stopDelay: Duration = .zero) {
        self.samples = samples
        self.startBehavior = startBehavior
        self.stopDelay = stopDelay
    }

    func start() async throws {
        try await start(deviceUID: nil)
    }

    /// Shares the same recording logic as `start()` (only ignoring the device selection, the fake implementation does not connect to real hardware).
    /// Lets this fake re-satisfy `AudioRecording` (the protocol requires `start(deviceUID:)`).
    func start(deviceUID: String?) async throws {
        startCount += 1
        lastStartDeviceUID = deviceUID
        // Manual gate (if armed): suspend here BEFORE flipping `recording`, pinning the "start in flight, suspended"
        // window until the test releases it — lets a cancel() be landed deterministically mid-start (the resurrection bug).
        if startGateArmed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                startGate = continuation
            }
        }
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
        // Manual gate (if armed): suspend here BEFORE flipping `recording`, pinning the "stop in flight, still recording" window
        // until the test releases it — lets a racing start() be driven deterministically into the unfinished stop.
        if stopGateArmed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                stopGate = continuation
            }
        }
        // Simulate the real recorder's engine teardown taking time: while this is in flight `recording` stays true,
        // so a racing start() that does not await this stop would see the recorder still busy (reproduces the cancel-then-restart bug).
        if stopDelay != .zero {
            try? await Task.sleep(for: stopDelay)
        }
        recording = false
        levelStream.endSession()
        return samples
    }

    /// Arms the stop gate: the NEXT `stop()` will suspend (still recording) until ``releaseStop()`` is called.
    func gateStop() { stopGateArmed = true }

    /// Releases a gated `stop()` (if currently suspended) and disarms the gate, letting the stop finish normally.
    func releaseStop() {
        stopGateArmed = false
        stopGate?.resume()
        stopGate = nil
    }

    /// Polls until a gated `stop()` has actually entered the suspend point (the continuation is captured), so the test can be sure
    /// the recorder is sitting in the "stop in flight, still recording" window before it drives the racing start.
    func waitUntilStopGated() async {
        while stopGate == nil {
            await Task.yield()
        }
    }

    /// Arms the start gate: the NEXT `start()` will suspend (before flipping `recording`) until ``releaseStart()`` is called.
    func gateStart() { startGateArmed = true }

    /// Releases a gated `start()` (if currently suspended) and disarms the gate, letting the start finish normally.
    func releaseStart() {
        startGateArmed = false
        startGate?.resume()
        startGate = nil
    }

    /// Polls until a gated `start()` has actually entered the suspend point (the continuation is captured), so the test can be
    /// sure the recorder is sitting in the "start in flight, suspended" window before it lands the cancel.
    func waitUntilStartGated() async {
        while startGate == nil {
            await Task.yield()
        }
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

/// A controllable fake focused-text reader for the learn-from-edits tests: returns a queued sequence of results
/// (one per `readFocusedText()` call) so a test can drive the ARM read (baseline) and the read-back (edited value) with
/// different values. When the queue runs dry it keeps returning the LAST queued result, so a single-value queue can serve
/// both reads. Records the call count for assertions. `@MainActor` to satisfy ``FocusedTextReading``.
@MainActor
final class FakeFocusedTextReader: FocusedTextReading {
    var trusted: Bool
    private var results: [FocusedText?]
    private(set) var readCount = 0

    /// - Parameters:
    ///   - trusted: the trust flag the protocol exposes; defaults to true.
    ///   - results: the queued read results, consumed one per `readFocusedText()`; the last one repeats once exhausted.
    init(trusted: Bool = true, results: [FocusedText?]) {
        self.trusted = trusted
        self.results = results
    }

    /// Convenience: a reader that always returns the same single value.
    convenience init(trusted: Bool = true, single: FocusedText?) {
        self.init(trusted: trusted, results: [single])
    }

    var isTrusted: Bool { trusted }

    func readFocusedText() -> FocusedText? {
        readCount += 1
        guard !results.isEmpty else { return nil }
        if results.count == 1 { return results[0] }
        return results.removeFirst()
    }
}

/// A no-op sound-cue player for the coordinator tests: satisfies ``SoundCuePlaying`` while rendering ZERO audio,
/// so driven `_test_start()`/`_test_stop()` never emit an audible chime. Reuses the existing ``SoundCuePlaying``
/// protocol (does not redeclare it). Production keeps using the real ``SoundCuePlayer`` via the init default.
@MainActor
final class SilentSoundCues: SoundCuePlaying {
    func play(_ cue: SoundCue) {}
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
