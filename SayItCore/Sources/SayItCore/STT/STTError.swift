import Foundation

/// Errors that may be thrown during Speech-To-Text transcription.
public enum STTError: Error, Equatable, Sendable {
/// The transcription backend is not ready yet (e.g. model not loaded, permission not granted).
    case notReady
/// The input audio is empty, with nothing to transcribe.
    case emptyAudio
/// Unsupported sample rate or audio format.
    case unsupportedFormat
/// Transcription failed, with a human-readable reason attached.
    case transcriptionFailed(reason: String)
}

extension STTError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notReady:
            return "STTError.notReady"
        case .emptyAudio:
            return "STTError.emptyAudio"
        case .unsupportedFormat:
            return "STTError.unsupportedFormat"
        case let .transcriptionFailed(reason):
            return "STTError.transcriptionFailed(reason: \(reason))"
        }
    }
}
