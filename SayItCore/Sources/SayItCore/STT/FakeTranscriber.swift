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

    /// Injects a complete preset result.
    public init(result: TranscriptionResult) {
        self.outcome = .success(result)
    }

    /// Convenience initializer: specify only the returned text, with all other fields using default values.
    public init(text: String) {
        self.outcome = .success(TranscriptionResult(text: text))
    }

    /// Injects an error so that every call throws it.
    public init(error: STTError) {
        self.outcome = .failure(error)
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
