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

        // First-launch guidance, exactly once: `hasCompletedFirstRun` ensures the guidance BODY runs at most once per
        // install. Set the flag FIRST, then run the body. (This flag guards the guidance only; the auto-download itself is
        // independently gated by ``ModelManager/shouldAutoDownloadOnFirstRun(firstRun:sttMode:isDownloaded:)`` inside the body.)
        let config = AppConfig.shared
        if !config.hasCompletedFirstRun {
            config.hasCompletedFirstRun = true
            runFirstRunGuidance(config: config)
        }
    }

    /// One-time first-launch guidance for a brand-new install: pick the device-preferred STT engine, auto-download
    /// the local model (only when it would actually help) and open Settings on the Speech tab so the user sees it.
    ///
    /// Device-preferred default: on hardware that actually supports Apple's system speech engine
    /// (``AppleSpeechSupport/isSupported()`` — macOS 26+ AND a non-empty locale catalog) AND when the user has not
    /// yet explicitly chosen an engine (``AppConfig/hasExplicitSTTMode`` is `false` on a fresh install), prefer
    /// `.appleSpeech` and persist it. Apple's model is system-managed, so the ~1.6GB WhisperKit auto-download is
    /// pointless and is skipped: the skip is automatic because the download gate
    /// (``ModelManager/shouldAutoDownloadOnFirstRun(firstRun:sttMode:isDownloaded:)``) only fires for `.local`, and
    /// we have just settled `sttMode` on `.appleSpeech`. On any unsupported device (or for a returning user with a
    /// persisted choice) nothing changes: `sttMode` stays at its `.local` baseline and the local model auto-downloads
    /// exactly as before. The probe is async, so the engine decision + download gate + Settings open run inside a
    /// `Task { @MainActor }`; `AppConfig` / `ModelManager.shared` are `@MainActor`, so there is no cross-actor sharing.
    ///
    /// Reuses the EXACT ``ModelManager/download()`` entry point the Settings "Download" button calls (via the
    /// process-shared ``ModelManager/shared``), so the first-run download, the Settings button, and the menu-bar
    /// indicator all drive/observe one state object — no duplicated download logic. A no-network / failed download
    /// lands on the existing `.failed` + retry path (no crash). The on-demand download in STT settings is untouched
    /// (a user who later switches to local can still download there).
    private func runFirstRunGuidance(config: AppConfig) {
        Task { @MainActor in
            // Apply the device-preferred default before deciding on the download: only when this is a truly fresh
            // install (no engine persisted yet) AND the hardware supports Apple speech. Otherwise leave `sttMode`
            // untouched (its `.local` baseline), preserving the exact prior behavior incl. the local auto-download.
            if !config.hasExplicitSTTMode, await AppleSpeechSupport.isSupported() {
                config.sttMode = .appleSpeech
            }

            // Now-gated: `shouldAutoDownloadOnFirstRun` requires `sttMode == .local`, so settling on `.appleSpeech`
            // above makes this skip the WhisperKit download; on unsupported devices `sttMode` is still `.local`
            // and the download fires exactly as before.
            if ModelManager.shouldAutoDownloadOnFirstRun(
                firstRun: true,
                sttMode: config.sttMode,
                isDownloaded: ModelManager.isDownloaded(model: config.localModel)
            ) {
                Task { await ModelManager.shared.download() }
            }

            // Open Settings on the Speech tab (not the default General) so the chosen engine and any download
            // progress are immediately visible. Routed through ``SettingsRouter`` so the SwiftUI scene calls the
            // live `@Environment(\.openSettings)` action: for an accessory (menu-bar) SwiftUI app the legacy AppKit
            // `NSApp.sendAction(showSettingsWindow:)` selector has no reliable responder target at launch, so it
            // silently failed to open anything. SettingsView reads the requested tab (set here via `requestOpen`)
            // in `.onAppear`; the scene activates the app after opening.
            SettingsRouter.shared.requestOpen(tab: .stt)
        }
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
