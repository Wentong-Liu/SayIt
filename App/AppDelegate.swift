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
