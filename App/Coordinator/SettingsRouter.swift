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

    /// A monotonically increasing token identifying the latest "please open Settings" request.
    /// Because this type is `@Observable`, mutating it fires a SwiftUI `.onChange` in the scene that
    /// observes it, where the live `@Environment(\.openSettings)` action can actually open the window.
    ///
    /// Why an ID counter rather than a `Bool`: it lets the observer fire exactly once per *new* request
    /// (compared against a remembered handled value) instead of having to reset shared mutable state,
    /// and a non-zero id distinguishes "a request was made" from the initial value.
    var openRequestID = 0

    /// Ask SwiftUI to open the Settings window on `tab` (`nil` = default General). Sets the consume-once
    /// ``pendingTab`` that ``SettingsView`` reads in `.onAppear`, then bumps ``openRequestID`` to signal
    /// the observing scene — which calls `openSettings()` where that action is live (an accessory
    /// menu-bar app cannot rely on the legacy AppKit `showSettingsWindow:` responder-chain selector).
    func requestOpen(tab: SettingsTab?) {
        pendingTab = tab
        openRequestID += 1
    }

    init() {}
}
