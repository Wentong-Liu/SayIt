import Foundation

/// A ``Transcriber`` fake implementation for testing and upper-module development.
///
/// You can inject a preset ``TranscriptionResult`` or an ``STTError``:
/// when a result is injected, every call returns that result; when an error is injected, every call throws that error.
/// Implemented as an `actor`, so it is `Sendable`, and it internally records the arguments of each call,
/// for tests to assert that argument passing is correct.
public actor FakeTranscriber: Transcriber {
    /// A snapshot of the arguments of one ``transcribe(_:sampleRate:language:options:)`` call.
    public struct Call: Equatable, Sendable {
        public let audio: [Float]
        public let sampleRate: Double
        public let language: String?
        /// The dictionary biasing terms threaded through the call (empty when no biasing), so tests can assert the
        /// coordinator wired the dictionary into the transcribe call.
        public let biasTerms: [String]

        public init(audio: [Float], sampleRate: Double, language: String?, biasTerms: [String] = []) {
            self.audio = audio
            self.sampleRate = sampleRate
            self.language = language
            self.biasTerms = biasTerms
        }
    }

    private enum Outcome: Sendable {
        case success(TranscriptionResult)
        case failure(STTError)
    }

    private let outcome: Outcome

    /// All call arguments recorded in call order.
    public private(set) var calls: [Call] = []

    /// Whether ``preload()`` has been called (lets a test assert the coordinator's cold-start gate did NOT preload when the
    /// transcriber was already warm — i.e. no "preparing model" flash in the common case).
    public private(set) var preloadCalled = false

    /// The cold-start readiness this fake reports via the ``Transcriber`` requirement. When `true` (the default) the
    /// coordinator's cold-start gate is skipped; when `false`, ``isReady`` flips to `true` only after ``preload()`` completes,
    /// so a test can assert the "Preparing model…" HUD state was shown while the (optionally gated) load was in flight.
    private var ready: Bool

    /// Optional preload gate: when armed via ``gatePreload()``, ``preload()`` suspends until ``releasePreload()`` is called,
    /// deterministically pinning the cold-start "preparing model" window so a test can observe the HUD state before the load
    /// completes (mirrors ``FakeAudioRecorder``'s stop/start gates). nil/unarmed -> preload completes immediately.
    private var preloadGate: CheckedContinuation<Void, Never>?
    private var preloadGateArmed = false

    /// Injects a complete preset result.
    /// - Parameter ready: the initial cold-start readiness (defaults to `true` = warm, so existing tests skip the gate).
    public init(result: TranscriptionResult, ready: Bool = true) {
        self.outcome = .success(result)
        self.ready = ready
    }

    /// Convenience initializer: specify only the returned text, with all other fields using default values.
    /// - Parameter ready: the initial cold-start readiness (defaults to `true` = warm).
    public init(text: String, ready: Bool = true) {
        self.outcome = .success(TranscriptionResult(text: text))
        self.ready = ready
    }

    /// Injects an error so that every call throws it.
    public init(error: STTError) {
        self.outcome = .failure(error)
        self.ready = true
    }

    public var isReady: Bool { ready }

    public func preload() async throws {
        preloadCalled = true
        // Manual gate (if armed): suspend here until the test releases it, pinning the cold-start "preparing" window.
        if preloadGateArmed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                preloadGate = continuation
            }
        }
        ready = true
    }

    /// Arms the preload gate: the NEXT ``preload()`` suspends until ``releasePreload()`` is called.
    public func gatePreload() { preloadGateArmed = true }

    /// Releases a gated ``preload()`` (if currently suspended) and disarms the gate, letting the load finish.
    public func releasePreload() {
        preloadGateArmed = false
        preloadGate?.resume()
        preloadGate = nil
    }

    /// Polls until a gated ``preload()`` has actually entered the suspend point (the continuation is captured), so a test
    /// can be sure the transcriber is sitting in the "preparing model" window before asserting the HUD state.
    public func waitUntilPreloadGated() async {
        while preloadGate == nil {
            await Task.yield()
        }
    }

    public func transcribe(_ audio: [Float], sampleRate: Double, language: String?, options: TranscribeOptions) async throws -> TranscriptionResult {
        calls.append(Call(audio: audio, sampleRate: sampleRate, language: language, biasTerms: options.biasTerms))
        switch outcome {
        case let .success(result):
            return result
        case let .failure(error):
            throw error
        }
    }
}
