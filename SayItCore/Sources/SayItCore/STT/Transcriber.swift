import Foundation

/// Abstract interface for a speech transcription backend.
///
/// Concrete implementations may be a local model (e.g. WhisperKit) or a cloud service; this protocol stays backend-agnostic,
/// upper layers depend only on this interface, making it easy to swap implementations and to inject ``FakeTranscriber`` in tests.
public protocol Transcriber: Sendable {
    /// Transcribes PCM float audio into text.
    ///
    /// - Parameters:
    ///   - audio: mono PCM samples, value range roughly `[-1, 1]`.
    ///   - sampleRate: audio sample rate (Hz), e.g. `16_000`.
    ///   - language: optional BCP-47 / ISO language code (e.g. `"en"`, `"zh"`);
    ///     passing `nil` lets the backend auto-detect.
    /// - Returns: the transcription result ``TranscriptionResult``.
    /// - Throws: ``STTError`` on transcription failure.
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?) async throws -> TranscriptionResult
}
