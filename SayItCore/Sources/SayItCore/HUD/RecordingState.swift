import Foundation

/// The display state of the dictation HUD.
///
/// The controller maps the current dictation phase to this enum, and the view switches icon/copy/animation accordingly:
/// - `idle`: idle (the HUD is usually hidden; this state is kept for state-machine convergence and testing).
/// - `listening`: recording / listening to the user speak.
/// - `transcribing`: recording finished, transcribing to text (old state, kept for backward compatibility).
/// - `processing`: in progress (Typeless-style progress bar): carries a 0...1 progress and the current phase (transcribing/polish).
///   The progress bar is driven by ``RecordingPanelView`` as a single client-side ease spanning the whole run (0→90% ease-out, ~3s);
///   the phase only selects the copy (Transcribing… / Polishing…) and never anchors the bar position; the backend's final 1.0 snaps it to 100%.
/// - `info`: a neutral hint (e.g. "pasted into the current window"), carrying short copy; not an error, uses a checkmark icon.
/// - `error`: an error, carrying short user-facing copy.
public enum RecordingState: Equatable, Sendable {
    /// The processing phase: transcribing (STT) or polish (LLM). It only selects the HUD copy and does not map to the progress-bar position.
    public enum ProcessingPhase: Equatable, Sendable {
        /// The local model is being loaded into memory (cold start) before transcription can begin. The copy shows Preparing model….
        /// Rides inside the existing `.processing(_:phase:)` state so it reuses the progress-bar ramp and never disturbs
        /// ``RecordingPanelView``'s exhaustive top-level switch over ``RecordingState`` (which never switches on the phase value).
        case preparingModel
        /// Transcribing to text. The copy shows Transcribing….
        case transcribing
        /// LLM polish. The copy shows Polishing….
        case polishing
    }

    case idle
    case listening
    case transcribing
    /// In progress: carries a 0...1 progress and the current phase, driving the HUD's progress bar and phase copy.
    case processing(progress: Double, phase: ProcessingPhase)
    case info(String)
    case error(String)

    /// The primary copy displayed by the HUD in this state. Fixed states use in-bundle localization (`Bundle.module`, en + zh-Hans);
    /// the specific copy carried by `info`/`error` is passed in by the caller (already in its language), only falling back to a localized generic hint when empty.
    public var displayText: String {
        switch self {
        case .idle:
            return Self.localized("hud.idle", fallback: "Ready")
        case .listening:
            return Self.localized("hud.listening", fallback: "Listening…")
        case .transcribing:
            return Self.localized("hud.transcribing", fallback: "Transcribing…")
        case .processing(_, let phase):
            // The processing copy switches with the phase; both phases resolve through the shared
            // in-bundle localized helper (en + zh-Hans), so no phase diverges from the catalog path.
            switch phase {
            case .preparingModel:
                return Self.localized("hud.preparingModel", fallback: "Preparing model…")
            case .transcribing:
                return Self.localized("hud.transcribing", fallback: "Transcribing…")
            case .polishing:
                return Self.localized("hud.polishing", fallback: "Polishing…")
            }
        case .info(let message):
            // Neutral hint: an empty message falls back to a generic hint, avoiding a blank HUD.
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.localized("hud.done", fallback: "Done") : trimmed
        case .error(let message):
            // Error copy: an empty message falls back to a generic hint, avoiding a blank HUD.
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.localized("hud.error", fallback: "Something went wrong") : trimmed
        }
    }

    /// Gets localized copy from the in-bundle `Localizable.xcstrings`, resolved in the app's
    /// currently-selected UI language (``AppConfig/uiLanguage``) rather than the system locale, so the
    /// HUD pill matches the rest of the UI and switches live with the setting (the HUD is rebuilt each
    /// dictation, so it reads the current language at show time). Falls back safely to English when the
    /// language's `.lproj` or the key is missing — never blank, never the bare key.
    private static func localized(_ key: String, fallback: String) -> String {
        UILanguageLocalizer.string(key, defaultValue: fallback, bundle: .module)
    }

    /// Processing progress (0...1). Only `.processing` returns a carried value, others are `nil`, for the view to bind directly.
    public var progress: Double? {
        if case .processing(let progress, _) = self { return progress }
        return nil
    }

    /// The current processing phase. Only `.processing` returns a carried phase, others are `nil`.
    public var processingPhase: ProcessingPhase? {
        if case .processing(_, let phase) = self { return phase }
        return nil
    }

    /// Whether this state should keep the HUD visible. `idle` does not display, all others do (including `.processing`).
    public var isVisible: Bool {
        self != .idle
    }

    /// User-facing localized hint copy for "the local model is not yet downloaded/ready" (en + zh-Hans, via in-bundle `Bundle.module`).
    ///
    /// Does not add an enum case (avoiding disturbing ``RecordingPanelView``'s exhaustive switch): the caller wraps it into an existing
    /// `.error(_:)`/`.info(_:)` state to display. When the local model is not cached, the local-transcription layer first triggers a download (possibly taking several minutes),
    /// during which the HUD stays stuck at "transcribing" appearing frozen; the upper layer accordingly gives this hint **before transcription** and converges,
    /// guiding the user to wait for the download to complete or switch to cloud.
    public static var modelNotReadyMessage: String {
        localized("hud.modelNotReady",
                  fallback: "Local model still downloading — please wait or switch to cloud")
    }

    /// Localized copy for when processing (any phase) takes longer than expected and the progress bar has stuck at the 90% ceiling and held
    /// (en + zh-Hans, via in-bundle `Bundle.module`).
    ///
    /// Substituted in place for the primary copy by ``RecordingPanelView`` after client-side timing (the ramp exceeding `processingRampDuration`),
    /// hinting "taking longer than usual". Does not add an enum case / phase, keeping the type and exhaustive switch unchanged (cleanly rebasable with parallel tasks).
    public static var takingLongerMessage: String {
        localized("hud.takingLonger", fallback: "Taking longer than usual…")
    }
}
