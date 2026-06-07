import Foundation

/// The result of one speech transcription.
///
/// `text` is the full transcription text; `segments` and `duration` are optional metadata
/// that different backends (local WhisperKit / cloud) may fill per capability, defaulting to an empty array and `nil` respectively when not provided.
public struct TranscriptionResult: Equatable, Sendable {
    /// A single time segment of the transcription.
    public struct Segment: Equatable, Sendable {
        /// The text of this segment.
        public let text: String
        /// Start time (seconds, relative to the audio start).
        public let start: Double
        /// End time (seconds, relative to the audio start).
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Full transcription text.
    public let text: String
    /// Segment information; an empty array when the backend does not support segmentation.
    public let segments: [Segment]
    /// Audio duration (seconds); `nil` when not provided by the backend.
    public let duration: Double?

    public init(text: String, segments: [Segment] = [], duration: Double? = nil) {
        self.text = text
        self.segments = segments
        self.duration = duration
    }
}
