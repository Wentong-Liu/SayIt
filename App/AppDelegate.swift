import AppKit
import SayItCore

/// Sets the App as a menu-bar agent: no Dock icon, does not steal main-window focus.
/// Implemented with the runtime `setActivationPolicy(.accessory)` (together with Info.plist's LSUIElement).
///
/// Also brings up the end-to-end dictation orchestrator ``DictationCoordinator`` at launch (hotkey -> recording -> transcription -> polish -> injection).
///
/// Authorization policy:
/// - Microphone: when undetermined, silently pop the system dialog (a side-effect-free, user-expected one-time request).
/// - Accessibility: ask immediately after the microphone prompt finishes, with ``DictationCoordinator`` still keeping the on-demand fallback.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        requestStartupPermissionsIfNeeded()

        // Start the end-to-end dictation orchestration, bridging the high-level state to an observable holder (the menu-bar icon refreshes accordingly).
        DictationCoordinator.shared.onPhaseChange = { phase in
            DictationStatus.shared.phase = phase
        }
        DictationCoordinator.shared.start()

        // Model-download readiness is surfaced by the menu-bar "ready" badge (SayItApp.menuBarLabel,
        // shown while sttMode == .local && !ModelManager.isDownloaded); no separate notifier.

        // First-launch guidance, exactly once (gated on the persisted flag). Set the flag FIRST so the
        // body is idempotent even if it returns early, then run the guidance.
        let config = AppConfig.shared
        if !config.hasCompletedFirstRun {
            config.hasCompletedFirstRun = true
            runFirstRunGuidance(config: config)
        }
    }

    /// One-time first-launch guidance for a brand-new install: auto-download the local model (only when
    /// it would actually help) and open Settings on the Speech tab so the user sees the progress.
    ///
    /// Reuses the EXACT ``ModelManager/download()`` entry point the Settings "Download" button calls (via
    /// the process-shared ``ModelManager/shared``), so the first-run download, the Settings button, and
    /// the menu-bar indicator all drive/observe one state object — no duplicated download logic. A
    /// no-network / failed download lands on the existing `.failed` + retry path (no crash). The download
    /// is gated on ``ModelManager/shouldAutoDownloadOnFirstRun(firstRun:sttMode:isDownloaded:)`` so an
    /// upgrading user (model already present) or a cloud-mode user gets no spurious download.
    private func runFirstRunGuidance(config: AppConfig) {
        if ModelManager.shouldAutoDownloadOnFirstRun(
            firstRun: true,
            sttMode: config.sttMode,
            isDownloaded: ModelManager.isDownloaded(model: config.localModel)
        ) {
            Task { await ModelManager.shared.download() }
        }

        // Open Settings on the Speech tab (not the default General) so the local-model section and the
        // download progress are immediately visible. Routed through ``SettingsRouter`` so the SwiftUI
        // scene calls the live `@Environment(\.openSettings)` action: for an accessory (menu-bar) SwiftUI
        // app the legacy AppKit `NSApp.sendAction(showSettingsWindow:)` selector has no reliable responder
        // target at launch, so it silently failed to open anything. SettingsView reads the requested tab
        // (set here via `requestOpen`) in `.onAppear`; the scene activates the app after opening.
        SettingsRouter.shared.requestOpen(tab: .stt)
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationCoordinator.shared.stop()
    }

    /// Microphone: when undetermined, pop the system dialog to request. Accessibility is requested right after that
    /// first prompt resolves, and visible windows are brought forward because accessory apps are not reliably
    /// reactivated by macOS after the permission sheet closes.
    private func requestStartupPermissionsIfNeeded() {
        if MicrophonePermission.current == .notDetermined {
            Task { @MainActor in
                _ = await MicrophonePermission.request()
                bringVisibleWindowsForward()
                requestAccessibilityIfNeeded()
            }
        } else {
            requestAccessibilityIfNeeded()
        }
    }

    private func requestAccessibilityIfNeeded() {
        if !AccessibilityAuthorization.isTrusted {
            AccessibilityAuthorization.ensureTrusted(prompting: true)
        }
    }

    private func bringVisibleWindowsForward() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible {
            window.orderFrontRegardless()
        }
    }
}
