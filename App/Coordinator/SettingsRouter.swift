import Observation

/// A tiny observable hand-off that lets non-SwiftUI code (``AppDelegate``) ask the Settings window to
/// open on a specific tab instead of its default General tab.
///
/// Why a dedicated type rather than folding onto ``DictationStatus``: it keeps the dictation-phase
/// semantics of `DictationStatus` untouched and gives the Settings scene a single, consume-once source
/// for the initial tab. ``SettingsView`` reads ``pendingTab`` in `.onAppear` and clears it immediately,
/// so it influences exactly one open and never strands a stale selection on later opens.
@MainActor
@Observable
final class SettingsRouter {
    /// Process-level shared instance: written by ``AppDelegate`` (first-run path), read+cleared by ``SettingsView``.
    static let shared = SettingsRouter()

    /// The tab the next Settings open should land on; `nil` means "use the default (General)".
    /// ``SettingsView`` consumes this once on appear and resets it to `nil`.
    var pendingTab: SettingsTab?

    init() {}
}
