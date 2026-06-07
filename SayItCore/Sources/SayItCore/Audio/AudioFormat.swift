import Foundation

/// The target audio format required by Whisper: 16kHz, mono, 32-bit float (PCM Float32).
///
/// The raw microphone stream captured by AudioRecorder (sample rate/channels depend on hardware) is converted to this format,
/// then accumulated into `[Float]` for later transcription. Centralized as a single source of truth for easy testing and reuse.
public enum AudioFormat {
    /// Target sample rate (Hz). The Whisper model is fixed-trained at 16kHz.
    public static let sampleRate: Double = 16_000

    /// Target channel count (mono).
    public static let channelCount: UInt32 = 1

    /// Bytes per sample (Float32 = 4 bytes).
    public static let bytesPerSample = 4
}
