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

            // A model-status line so the download progress / not-ready state is visible in the menu even
            // when Settings is closed. Reads the shared `@Observable` ModelManager state directly (no poll).
            if let status = modelStatusText {
                Text(status)
                Divider()
            }

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
            // The label observes `ModelManager.shared.state` (an `@Observable`): reading `.state` here
            // registers SwiftUI tracking, so the icon re-renders on every download progress / completion
            // change with NO polling. While downloading, append a "NN%" readout; while the local engine
            // is selected but the model is missing, overlay a persistent "setup needed" badge.
            menuBarLabel
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

    // MARK: - Menu-bar model-status presentation

    /// The status-item label: the monochrome speech mark, plus a live download-percentage suffix while
    /// downloading and a persistent "setup needed" badge while the local engine is selected but the
    /// model is not yet on disk. Reading `ModelManager.shared.state` here registers `@Observable`
    /// tracking, so the label re-renders on state change without polling.
    @ViewBuilder
    private var menuBarLabel: some View {
        let _ = uiLocale
        if case .downloading(let progress, _) = ModelManager.shared.state {
            // Icon + a compact percentage so a brand-new user sees the install is in progress.
            HStack(spacing: 3) {
                Image("MenuBarIcon")
                Text(verbatim: "\(Int(progress * 100))%")
            }
            .accessibilityLabel("SayIt")
        } else if needsLocalModel {
            // Persistent "setup needed" badge overlaid on the icon: the local engine is selected but
            // its model is absent (state `.notDownloaded`/`.failed` while sttMode == .local).
            Image("MenuBarIcon")
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel("SayIt")
        } else {
            Image("MenuBarIcon")
                .accessibilityLabel("SayIt")
        }
    }

    /// Whether the local engine is selected but its model is not yet usable — the condition that drives
    /// the "setup needed" badge / menu line.
    private var needsLocalModel: Bool {
        AppConfig.shared.sttMode == .local && !ModelManager.isDownloaded(model: AppConfig.shared.localModel)
    }

    /// A localized status line for the dropdown menu so the download progress / not-ready state is
    /// visible on open even with Settings closed; `nil` when the model is ready (no line needed).
    private var modelStatusText: String? {
        if case .downloading(let progress, _) = ModelManager.shared.state {
            return uiLanguageLocalized(format: "menu.modelDownloading %d",
                                       defaultValue: "Downloading model… %d%%",
                                       Int(progress * 100))
        }
        if needsLocalModel {
            return uiLanguageLocalized("menu.modelNotReady",
                                       defaultValue: "Setup needed — local model not downloaded")
        }
        return nil
    }
}
