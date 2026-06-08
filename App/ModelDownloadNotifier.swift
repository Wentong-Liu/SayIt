import Observation
import UserNotifications
import SayItCore

/// Posts a single, non-spammy local notification when the shared ``ModelManager`` finishes downloading
/// the local model (transitions INTO ``ModelManager/State/downloaded``).
///
/// Design:
/// - **Edge-triggered, not level-triggered**: it remembers the previously-seen state and fires only on
///   the transition `<anything but .downloaded> -> .downloaded`, so it never re-fires for a model that
///   was already present at launch (an upgrading user), and never fires twice for one download.
/// - **No polling**: it re-arms its observation each time `ModelManager.shared.state` changes via
///   `withObservationTracking` (the manager is `@Observable`), so it reacts only when the state actually moves.
/// - **Lazy authorization**: it requests notification authorization once, on the first observed
///   `.downloading` transition (i.e. only on the path where we actually intend to notify), so an
///   upgrading user who never downloads is never prompted.
///
/// The non-sandboxed app has a bundle id and needs no special entitlement to use
/// `UNUserNotificationCenter`. The menu-bar "ready" badge flip happens independently (it observes the
/// same state in the SwiftUI label), so even if the banner is suppressed the readiness is still visible.
@MainActor
@Observable
final class ModelDownloadNotifier {
    /// Process-level shared instance, started once from ``AppDelegate``.
    static let shared = ModelDownloadNotifier()

    /// The last state we observed, to detect the edge into `.downloaded` (and the first `.downloading`).
    @ObservationIgnored private var lastState: ModelManager.State?

    /// Whether we have already requested notification authorization (request at most once).
    @ObservationIgnored private var didRequestAuthorization = false

    /// Whether observation has been armed (start at most once).
    @ObservationIgnored private var started = false

    init() {}

    /// Begins observing ``ModelManager/shared``'s state. Idempotent: safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        lastState = ModelManager.shared.state
        observe()
    }

    /// Re-arms a one-shot observation of `ModelManager.shared.state`; on each change it handles the
    /// transition and re-arms, so it tracks the live state without any timer/poll.
    private func observe() {
        withObservationTracking {
            _ = ModelManager.shared.state
        } onChange: {
            Task { @MainActor [weak self] in
                self?.handleStateChange()
            }
        }
    }

    /// Processes one state change: requests authorization lazily when a download begins, posts the
    /// completion notification on the edge into `.downloaded`, then re-arms the observation.
    private func handleStateChange() {
        let previous = lastState
        let current = ModelManager.shared.state
        lastState = current

        // Lazily request authorization the first time a download actually begins, so an upgrading
        // user (model already present, never downloads) is never prompted.
        if case .downloading = current {
            requestAuthorizationIfNeeded()
        }

        // Fire only on the edge INTO .downloaded (never level-triggered, never twice).
        if current == .downloaded, previous != .downloaded {
            postReadyNotification()
        }

        observe()
    }

    /// Requests notification authorization once (alert + sound). Failures are ignored — the menu-bar
    /// badge flip remains the guaranteed readiness signal.
    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts the "SayIt is ready" completion banner in the selected UI language.
    private func postReadyNotification() {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = uiLanguageLocalized("notif.modelReady.title", defaultValue: "SayIt is ready")
        content.body = uiLanguageLocalized(
            "notif.modelReady.body",
            defaultValue: "The local model is installed — dictation now runs offline.")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "com.liuwentong.SayIt.modelReady",
            content: content,
            trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }
}
