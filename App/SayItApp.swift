import SwiftUI
import SayItCore

@main
struct SayItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openSettings) private var openSettings

    /// 应用配置：监听其变更以即时应用界面语言。
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
                // 设置页里切换界面语言后，立即把新 Locale 应用到设置窗口与菜单，无需重启即可见效。
                .onReceive(NotificationCenter.default.publisher(for: AppConfig.didChangeNotification)) { _ in
                    uiLocale = AppConfig.shared.uiLanguage.locale
                }
        }
    }
}
