import SwiftUI
import SayItCore

@main
struct SayItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openSettings) private var openSettings

    /// The application config: observes its changes to instantly apply the UI language.
    @State private var uiLocale: Locale = AppConfig.shared.uiLanguage.locale

    /// The last ``SettingsRouter/openRequestID`` this scene has already handled by calling `openSettings()`.
    /// Guards the open-on-request observer so it fires exactly once per *new*, non-zero id — not on every
    /// view update (where `.onChange`/`.task` could otherwise re-run). The first-run guidance issues its
    /// request at launch (possibly before this label first appears), so the request is honored on appear
    /// AND on later change.
    @State private var handledSettingsOpenRequestID = 0

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
                // Open Settings when ``SettingsRouter`` requests it (first-run guidance). This must live
                // here, in the MenuBarExtra label, because `@Environment(\.openSettings)` is only live in
                // a SwiftUI scene — the path the menu's "Settings…" button already uses successfully. The
                // accessory app's launch-time `NSApp.sendAction(showSettingsWindow:)` had no reliable
                // responder target, so it never opened. The request may be issued at launch before this
                // label first appears, so honor it both on appear (.task) and on later change (.onChange);
                // the `handledSettingsOpenRequestID` guard makes it fire exactly once per new, non-zero id.
                .task { openSettingsIfRequested() }
                .onChange(of: SettingsRouter.shared.openRequestID) { openSettingsIfRequested() }
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

    // MARK: - First-run / programmatic Settings open

    /// Open the Settings window via the live `@Environment(\.openSettings)` action if ``SettingsRouter``
    /// has a new, unhandled, non-zero open request, then bring the window to front (an accessory app does
    /// not auto-activate). Idempotent: the `handledSettingsOpenRequestID` guard ensures exactly one open
    /// per request id, so re-running on every view update / appear does nothing extra. `SettingsView`
    /// reads `SettingsRouter.shared.pendingTab` in `.onAppear` to select the requested tab.
    @MainActor
    private func openSettingsIfRequested() {
        let requestID = SettingsRouter.shared.openRequestID
        guard requestID != 0, requestID != handledSettingsOpenRequestID else { return }
        handledSettingsOpenRequestID = requestID
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu-bar model-status presentation

    /// The status-item label: the monochrome speech mark, plus a live download-percentage suffix while
    /// downloading and a persistent "setup needed" badge while the local engine is selected but the
    /// model is not yet on disk. Reading `ModelManager.shared.state` here registers `@Observable`
    /// tracking, so the label re-renders on state change without polling.
    @ViewBuilder
    private var menuBarLabel: some View {
        let _ = uiLocale
        switch menuBarModelReadiness {
        case .downloading(let percent):
            // Icon + a compact percentage so a brand-new user sees the install is in progress.
            HStack(spacing: 3) {
                Image("MenuBarIcon")
                Text(verbatim: "\(percent)%")
            }
            .accessibilityLabel("SayIt")
        case .needsLocalModel:
            // Persistent "setup needed" badge overlaid on the icon: the local engine is selected but
            // its model is absent (state `.notDownloaded`/`.failed` while sttMode == .local).
            Image("MenuBarIcon")
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel("SayIt")
        case .ready:
            Image("MenuBarIcon")
                .accessibilityLabel("SayIt")
        }
    }

    /// Whether the local engine is selected but its model is not yet usable — the condition that drives
    /// the "setup needed" badge / menu line.
    private var needsLocalModel: Bool {
        AppConfig.shared.sttMode == .local && !ModelManager.isDownloaded(model: AppConfig.shared.localModel)
    }

    /// The single classification of `ModelManager.shared.state` + `needsLocalModel` into the three menu-bar
    /// presentations, so `menuBarLabel` and `modelStatusText` read the identical percentage (`Int(progress*100)`)
    /// and the identical not-ready condition from ONE place. Evaluated inside the view bodies, so reading
    /// `ModelManager.shared.state` here still registers `@Observable` tracking (the no-poll re-render is preserved).
    private enum MenuBarModelReadiness {
        case downloading(percent: Int)
        case needsLocalModel
        case ready
    }

    private var menuBarModelReadiness: MenuBarModelReadiness {
        if case .downloading(let progress, _) = ModelManager.shared.state {
            return .downloading(percent: Int(progress * 100))
        }
        if needsLocalModel {
            return .needsLocalModel
        }
        return .ready
    }

    /// A localized status line for the dropdown menu so the download progress / not-ready state is
    /// visible on open even with Settings closed; `nil` when the model is ready (no line needed).
    private var modelStatusText: String? {
        switch menuBarModelReadiness {
        case .downloading(let percent):
            return uiLanguageLocalized(format: "menu.modelDownloading %d",
                                       defaultValue: "Downloading model… %d%%",
                                       percent)
        case .needsLocalModel:
            return uiLanguageLocalized("menu.modelNotReady",
                                       defaultValue: "Setup needed — local model not downloaded")
        case .ready:
            return nil
        }
    }
}
