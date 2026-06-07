import SwiftUI
import SayItCore

@main
struct SayItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openSettings) private var openSettings

    /// The application config: observes its changes to instantly apply the UI language.
    @State private var uiLocale: Locale = AppConfig.shared.uiLanguage.locale

    var body: some Scene {
        // The status item uses the app's own speech mark as a monochrome
        // template image ("MenuBarIcon"), so AppKit recolors it for light/dark
        // menu bars. The title stays "SayIt" for VoiceOver accessibility.
        MenuBarExtra {
            Button("menu.settings") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("menu.quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image("MenuBarIcon")
                .accessibilityLabel("SayIt")
        }
        .environment(\.locale, uiLocale)

        Settings {
            SettingsView()
                .environment(\.locale, uiLocale)
                // After switching the UI language in the settings page, immediately apply the new Locale to the settings window and menu, taking effect without a restart.
                .onReceive(NotificationCenter.default.publisher(for: AppConfig.didChangeNotification)) { _ in
                    uiLocale = AppConfig.shared.uiLanguage.locale
                }
        }
    }
}
