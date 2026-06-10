import Foundation

/// Per-call options that tune one transcription, kept separate from the audio/sampleRate/language arguments so the
/// protocol can grow without breaking every call site.
///
/// Currently carries the user-dictionary **Layer 1** biasing terms: a best-effort recall boost steering speech-to-text
/// toward the user's canonical dictionary words. Empty `biasTerms` means "no biasing" — byte-identical behavior to before
/// this feature existed.
public struct TranscribeOptions: Sendable, Equatable {
    /// Canonical dictionary terms to bias the transcription toward (most-relevant ordering is handled downstream).
    /// Empty -> no prompt is built anywhere (local `promptTokens` stays nil, cloud `prompt` field is omitted).
    public var biasTerms: [String]

    public init(biasTerms: [String] = []) {
        self.biasTerms = biasTerms
    }

    /// The neutral, biasing-disabled options (empty term list). Use this to preserve current behavior.
    public static let none = TranscribeOptions()
}

/// Abstract interface for a speech transcription backend.
///
/// Concrete implementations may be a local model (e.g. WhisperKit) or a cloud service; this protocol stays backend-agnostic,
/// upper layers depend only on this interface, making it easy to swap implementations and to inject ``FakeTranscriber`` in tests.
public protocol Transcriber: Sendable {
    /// Transcribes PCM float audio into text, optionally biased toward dictionary terms.
    ///
    /// This is the single protocol requirement; the 3-argument ``transcribe(_:sampleRate:language:)`` convenience below
    /// forwards to it with ``TranscribeOptions/none``, so existing 3-argument call sites keep compiling unchanged while
    /// conformers only need to implement this one method. (Swift forbids default parameter values on protocol requirements,
    /// so the convenience overload is the minimal idiomatic way to keep `options` optional for callers.)
    ///
    /// - Parameters:
    ///   - audio: mono PCM samples, value range roughly `[-1, 1]`.
    ///   - sampleRate: audio sample rate (Hz), e.g. `16_000`.
    ///   - language: optional BCP-47 / ISO language code (e.g. `"en"`, `"zh"`);
    ///     passing `nil` lets the backend auto-detect.
    ///   - options: per-call tuning (e.g. dictionary biasing terms); ``TranscribeOptions/none`` disables biasing.
    /// - Returns: the transcription result ``TranscriptionResult``.
    /// - Throws: ``STTError`` on transcription failure.
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?, options: TranscribeOptions) async throws -> TranscriptionResult

    /// Whether the backend's engine is already loaded into memory and a transcribe call would NOT block on a cold load.
    ///
    /// Only the local ``WhisperKitTranscriber`` has a meaningful cold-start window (the CoreML engine is `nil` right after
    /// launch — before opportunistic prewarm finishes — or right after a model switch), so it overrides this. Every other
    /// conformer (cloud, test doubles) inherits the default `true`: they have no in-memory engine to preload, so a transcribe
    /// call never blocks on loading and the coordinator's "preparing model" gate is skipped for them. See the default below.
    ///
    /// `async` so an `actor` conformer (``WhisperKitTranscriber``, ``FakeTranscriber``) can satisfy it from its own isolation
    /// without crossing into a data race — a synchronous `get` requirement would be `nonisolated` and an actor's isolated
    /// stored state could not satisfy it under Swift 6 strict concurrency. Callers read it with `await transcriber.isReady`.
    var isReady: Bool { get async }

    /// Loads the backend's engine into memory if it is not already, so a subsequent transcribe call is warm.
    ///
    /// Idempotent: a second call (or a call while the in-flight background prewarm is already running) is a cheap no-op /
    /// join. Only ``WhisperKitTranscriber`` does real work (loads the CoreML engine and maps any failure to
    /// ``STTError/transcriptionFailed(reason:)``); every other conformer inherits the default no-op (nothing to load). See
    /// the default below. The clean ``STTError/notReady``-on-absent guarantee applies to the call that INITIATES the load; a
    /// call that coalesces onto an already-in-flight load that fails inherits the generic ``STTError/transcriptionFailed(reason:)``.
    func preload() async throws
}

public extension Transcriber {
    /// Default: ready. Backends with no in-memory engine (cloud, test doubles) are always warm, so they skip the
    /// coordinator's "preparing model" gate. ``WhisperKitTranscriber`` overrides this with `engine != nil`.
    var isReady: Bool { get async { true } }

    /// Default: no-op. Backends with no in-memory engine have nothing to preload. ``WhisperKitTranscriber`` overrides this
    /// to load (and download if needed) the CoreML engine.
    func preload() async throws {}

    /// Backward-compatible convenience: transcribe with no biasing options. Forwards to the 4-argument requirement.
    ///
    /// This keeps all existing 3-argument callers and tests working without change. There is intentionally NO default
    /// implementation of the 4-argument requirement here — conformers implement it directly — so the two methods never
    /// recurse into each other.
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?) async throws -> TranscriptionResult {
        try await transcribe(audio, sampleRate: sampleRate, language: language, options: .none)
    }
}
