import SwiftUI
import SayItCore

@main
struct SayItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openSettings) private var openSettings

    /// 听写高层状态的可观察持有者；驱动菜单栏图标。
    @State private var status = DictationStatus.shared

    /// 应用配置：监听其变更以即时应用界面语言。
    @State private var uiLocale: Locale = AppConfig.shared.uiLanguage.locale

    var body: some Scene {
        MenuBarExtra("SayIt", systemImage: menuBarSymbol) {
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

    /// 菜单栏图标：聆听中 / 识别中各用不同符号反映状态，其余为常态麦克风。
    private var menuBarSymbol: String {
        switch status.phase {
        case .listening: return "mic.circle.fill"
        case .working:   return "waveform.circle.fill"
        case .idle:      return "mic.fill"
        }
    }
}
