import Foundation

/// Errors that may occur during recording.
public enum AudioRecordingError: Error, Sendable {
/// Microphone permission not granted (denied/restricted/user not authorized).
    case microphonePermissionDenied
/// Already recording, with `start()` called again.
    case alreadyRecording
/// Not currently recording, yet `stop()` was called.
    case notRecording
/// Cannot build a converter to the target format for the input stream (sample-rate/channel conversion failed).
    case converterUnavailable
/// AVAudioEngine failed to start, with the underlying error description attached.
    case engineStartFailed(String)
}

extension AudioRecordingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .microphonePermissionDenied:
            return "AudioRecordingError.microphonePermissionDenied"
        case .alreadyRecording:
            return "AudioRecordingError.alreadyRecording"
        case .notRecording:
            return "AudioRecordingError.notRecording"
        case .converterUnavailable:
            return "AudioRecordingError.converterUnavailable"
        case let .engineStartFailed(message):
            return "AudioRecordingError.engineStartFailed(\(message))"
        }
    }
}

/// Microphone recording abstraction: start capture, stop, and retrieve the accumulated Float32 mono 16kHz samples.
///
/// Designed as a protocol so upper layers (the dictation pipeline) depend on the abstraction and can swap in a fake implementation in unit tests,
/// and so the underlying capture approach can be replaced later without affecting callers.
///
/// Contract: the samples returned by `stop()` are exactly `AudioFormat` (16kHz / mono / Float32).
public protocol AudioRecording: Sendable {
    /// Start recording (using the system default input device). If unauthorized it first tries to request permission; if still unauthorized it throws
    /// `.microphonePermissionDenied`. Throws `.alreadyRecording` when already recording.
    func start() async throws

    /// Start recording with a specified input device.
    ///
    /// - Parameter deviceUID: target input device UID (``AudioInputDevice/uid``);
    ///   passing `nil` is equivalent to ``start()`` (system default device).
    ///   If the UID resolves to no device (unplugged/invalid), it automatically falls back to the system default device.
    /// All other behavior matches ``start()`` (permission, 16kHz/mono/Float32, levels stream).
    func start(deviceUID: String?) async throws

    /// Stop recording and return all samples accumulated this time (16kHz / mono / Float32).
    /// Throws `.notRecording` when not recording.
    @discardableResult
    func stop() async throws -> [Float]

    /// Whether recording is in progress.
    var isRecording: Bool { get async }

    /// Real-time input level stream: each captured buffer segment produces one normalized RMS level (0...1).
    ///
    /// Consumed by the HUD waveform/volume indicator (`for await level in recorder.levels { ... }`).
    /// No new values are produced after recording stops; stays valid across multiple recordings (same long-lived stream).
    /// 0 means silence, 1 means near full scale. The exact mapping is implementation-defined (may include log compression to match perception).
    var levels: AsyncStream<Double> { get }
}

public extension AudioRecording {
    /// Default implementation: start recording with the system default input device (forwards to `start(deviceUID: nil)`).
    /// This both keeps the existing caller's `start()` unchanged and gives types that only implement `start(deviceUID:)` an automatic version of it.
    func start() async throws {
        try await start(deviceUID: nil)
    }
}
