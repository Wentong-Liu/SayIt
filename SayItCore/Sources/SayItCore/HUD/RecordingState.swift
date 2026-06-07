import Foundation

/// The display state of the dictation HUD.
///
/// The controller maps the current dictation phase to this enum, and the view switches icon/copy/animation accordingly:
/// - `idle`: idle (the HUD is usually hidden; this state is kept for state-machine convergence and testing).
/// - `listening`: recording / listening to the user speak.
/// - `transcribing`: recording finished, transcribing to text (old state, kept for backward compatibility).
/// - `processing`: in progress (Typeless-style progress bar): carries a 0...1 progress and the current phase (transcribing/polish).
///   0...0.5 is transcribing (STT), 0.5...1 is polish (LLM); when polish is off, transcription completion fills directly to 1.0.
/// - `info`: a neutral hint (e.g. "pasted into the current window"), carrying short copy; not an error, uses a checkmark icon.
/// - `error`: an error, carrying short user-facing copy.
public enum RecordingState: Equatable, Sendable {
    /// The processing phase (for the Typeless-style progress bar): transcribing (STT) or polish (LLM).
    public enum ProcessingPhase: Equatable, Sendable {
        /// Transcribing to text (progress 0...0.5).
        case transcribing
        /// LLM polish (progress 0.5...1).
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
            // The processing copy switches with the phase: transcribing reuses the already-localized hud.transcribing;
            // the polish copy hud.polishing is not in the in-bundle xcstrings (limited by the change scope), so it falls back bilingually in place per UI language.
            switch phase {
            case .transcribing:
                return Self.localized("hud.transcribing", fallback: "Transcribing…")
            case .polishing:
                return Self.polishingLabel
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

    /// Gets localized copy from the in-bundle `Localizable.xcstrings`; when missing it falls back to English, guaranteeing it is not blank.
    private static func localized(_ key: String, fallback: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .module, comment: "Recording HUD state text")
            .nonKeyOr(fallback, key: key)
    }

    /// Polish-phase copy. `hud.polishing` is not yet in the in-bundle xcstrings (limited by the change scope),
    /// so it falls back bilingually in place per the current UI language: Chinese returns the polish-in-progress copy, others return English.
    private static var polishingLabel: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "润色中…" : "Polishing…"
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

    /// Localized copy for when the polish (`.polishing`) phase takes longer than expected and the progress bar has stuck at the 90% ceiling and held
    /// (en + zh-Hans, via in-bundle `Bundle.module`).
    ///
    /// Substituted in place for the primary copy by ``RecordingPanelView`` after client-side timing (polish start exceeding `expectedPolishDuration`),
    /// hinting "taking longer than usual". Does not add an enum case / phase, keeping the type and exhaustive switch unchanged (cleanly rebasable with parallel tasks).
    public static var takingLongerMessage: String {
        localized("hud.takingLonger", fallback: "Taking longer than usual…")
    }
}

private extension String {
    /// When the localization key is not found, `String(localized:)` returns the key name as-is; in that case fall back to English.
    func nonKeyOr(_ fallback: String, key: String) -> String {
        self == key ? fallback : self
    }
}
