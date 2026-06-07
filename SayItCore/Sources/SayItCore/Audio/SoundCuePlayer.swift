import AppKit

/// The dictation feedback cues: a short ASCENDING chime when dictation begins, a DESCENDING chime when it ends.
public enum SoundCue: String, Sendable {
    /// Ascending chime — recording has started.
    case start
    /// Descending chime — recording has stopped.
    case stop

    /// The bundled CAF resource base name (loaded from `Bundle.module`, see ``SoundCuePlayer``).
    var resourceName: String { rawValue }
}

/// Plays a named dictation cue. Abstracted behind a protocol so the dictation coordinator can inject a
/// no-op double in headless tests (CI must not emit audio), while production uses ``SoundCuePlayer``.
@MainActor
public protocol SoundCuePlaying {
    /// Fire-and-forget: trigger the cue and return immediately, never blocking the caller.
    func play(_ cue: SoundCue)
}

/// Plays the bundled start/stop chime cues, fire-and-forget and non-blocking.
///
/// Design points:
/// - **Non-blocking**: uses `NSSound.play()`, which returns immediately and renders the audio asynchronously
///   on the system audio thread. It never `await`s, never touches the recorder actor, and is not on the
///   recording/transcription path, so it cannot stall dictation.
/// - **Silent on failure**: if the CAF resource is missing or fails to load, the call is a no-op — it never
///   throws into the dictation pipeline.
/// - **Cached**: each cue's `NSSound` is built once from its `Bundle.module` URL and reused on later plays.
@MainActor
public final class SoundCuePlayer: SoundCuePlaying {
    /// Lazily-built, reused `NSSound` per cue (nil if the resource could not be loaded — stays a no-op).
    private var sounds: [SoundCue: NSSound] = [:]

    public init() {}

    public func play(_ cue: SoundCue) {
        guard let sound = sound(for: cue) else { return }
        // Restart from the beginning if it is still ringing from a previous rapid press.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Returns the cached `NSSound` for the cue, loading it from `Bundle.module` on first use.
    /// A missing/failed resource caches nothing and returns nil, so playback silently no-ops.
    private func sound(for cue: SoundCue) -> NSSound? {
        if let existing = sounds[cue] { return existing }
        guard let url = Bundle.module.url(forResource: cue.resourceName, withExtension: "caf"),
              let sound = NSSound(contentsOf: url, byReference: true) else {
            return nil
        }
        sounds[cue] = sound
        return sound
    }
}
