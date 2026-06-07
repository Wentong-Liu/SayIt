import Observation
import SayItCore

/// An observable holder of the high-level dictation state: bridges ``DictationCoordinator``'s `phase` to SwiftUI (the menu-bar icon).
///
/// The orchestrator is `@MainActor` and callbacks fire on the main thread, so this type is also `@MainActor`, and the UI can just read `phase` to react.
@MainActor
@Observable
final class DictationStatus {
    /// Process-level shared instance: written by ``AppDelegate``, read by ``SayItApp``.
    static let shared = DictationStatus()

    /// The current dictation phase (idle / listening / working).
    var phase: DictationCoordinator.Phase = .idle

    init() {}
}
