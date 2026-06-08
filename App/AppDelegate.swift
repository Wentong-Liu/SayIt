import AppKit
import SayItCore

/// Sets the App as a menu-bar agent: no Dock icon, does not steal main-window focus.
/// Implemented with the runtime `setActivationPolicy(.accessory)` (together with Info.plist's LSUIElement).
///
/// Also brings up the end-to-end dictation orchestrator ``DictationCoordinator`` at launch (hotkey -> recording -> transcription -> polish -> injection).
///
/// Authorization policy (avoiding disturbing the user at launch):
/// - Microphone: when undetermined, silently pop the system dialog (a side-effect-free, user-expected one-time request).
/// - Accessibility: **does not open System Settings at launch**; instead guided by ``DictationCoordinator`` when the user first presses the dictation key
///   and it is found unauthorized (on demand, matching intent).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // First run only guides microphone permission (system dialog, user-expected). Accessibility is instead guided on demand when the dictation key is pressed.
        requestMicrophoneIfNeeded()

        // Start the end-to-end dictation orchestration, bridging the high-level state to an observable holder (the menu-bar icon refreshes accordingly).
        DictationCoordinator.shared.onPhaseChange = { phase in
            DictationStatus.shared.phase = phase
        }
        DictationCoordinator.shared.start()

        // Watch the shared model manager so a finished download surfaces a one-time "ready" banner.
        // Idempotent and edge-triggered, so an upgrading user (model already present) never gets one.
        ModelDownloadNotifier.shared.start()

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
        // download progress are immediately visible. Reuses the standard macOS Settings-open action that
        // backs the menu's `openSettings()`; SettingsView reads the requested tab in `.onAppear`.
        SettingsRouter.shared.pendingTab = .stt
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationCoordinator.shared.stop()
    }

    /// Microphone: when undetermined, pop the system dialog to request (after the user denies, the dictation flow hints in the HUD).
    private func requestMicrophoneIfNeeded() {
        if MicrophonePermission.current == .notDetermined {
            Task { _ = await MicrophonePermission.request() }
        }
    }
}
