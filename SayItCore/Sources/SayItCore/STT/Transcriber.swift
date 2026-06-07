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
}

public extension Transcriber {
    /// Backward-compatible convenience: transcribe with no biasing options. Forwards to the 4-argument requirement.
    ///
    /// This keeps all existing 3-argument callers and tests working without change. There is intentionally NO default
    /// implementation of the 4-argument requirement here — conformers implement it directly — so the two methods never
    /// recurse into each other.
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?) async throws -> TranscriptionResult {
        try await transcribe(audio, sampleRate: sampleRate, language: language, options: .none)
    }
}
