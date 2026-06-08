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
            // Resolve the two menu labels through the #67/#76 UI-language helper rather than as
            // `LocalizedStringKey`s. The MenuBarExtra menu is built lazily on first open, and the
            // `.environment(\.locale, uiLocale)` override below is NOT applied to the menu items on that
            // first render — so `Button("menu.settings")` resolved against the SYSTEM locale and showed
            // Chinese on a Chinese-system Mac even with Display Language = English (only a later re-render
            // picked up the override). The helper reads the app's selected UI language directly, so it is
            // correct on the FIRST open, independent of the SwiftUI environment render timing.
            //
            // `uiLocale` is referenced in the resolution key so the body still re-renders — and these
            // labels re-evaluate — when the user switches the UI language (the `uiLocale` @State is
            // updated on AppConfig.didChangeNotification in the Settings scene below).
            let _ = uiLocale
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Text(uiLanguageLocalized("menu.settings", defaultValue: "Settings…"))
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text(uiLanguageLocalized("menu.quit", defaultValue: "Quit SayIt"))
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
