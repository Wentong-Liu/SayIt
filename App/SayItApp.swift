import SwiftUI
import SayItCore

@main
struct SayItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openSettings) private var openSettings

    /// 听写高层状态的可观察持有者；驱动菜单栏图标与状态文案。
    @State private var status = DictationStatus.shared

    var body: some Scene {
        MenuBarExtra("SayIt", systemImage: menuBarSymbol) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("设置…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("退出 SayIt") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        Settings {
            SettingsView()
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

    /// 菜单首项的状态文案。
    private var statusText: String {
        switch status.phase {
        case .idle:      return "就绪"
        case .listening: return "聆听中…"
        case .working:   return "识别中…"
        }
    }
}
