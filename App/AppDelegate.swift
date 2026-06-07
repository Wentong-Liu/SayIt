import AppKit
import SayItCore

/// 把 App 设为菜单栏代理：无 Dock 图标、不抢主窗口焦点。
/// 用运行时 `setActivationPolicy(.accessory)` 实现（配合 Info.plist 的 LSUIElement）。
///
/// 同时在启动时拉起端到端听写编排器 ``DictationCoordinator``（热键 → 录音 → 转写 → 润色 → 注入），
/// 并首次引导麦克风与辅助功能授权（全局热键 / 文本注入的前置条件）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 首次运行引导授权：麦克风（录音）+ 辅助功能（全局热键 / 注入）。
        requestPermissionsIfNeeded()

        // 启动端到端听写编排，把高层状态桥接到可观察持有者（菜单栏图标据此刷新）。
        DictationCoordinator.shared.onPhaseChange = { phase in
            DictationStatus.shared.phase = phase
        }
        DictationCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationCoordinator.shared.stop()
    }

    /// 首次运行的授权引导：
    /// - 麦克风：未决定时弹系统对话框请求（用户拒绝后由听写流程在 HUD 提示）。
    /// - 辅助功能：未信任时打开「系统设置 › 隐私与安全性 › 辅助功能」，引导用户开启。
    private func requestPermissionsIfNeeded() {
        if MicrophonePermission.current == .notDetermined {
            Task { _ = await MicrophonePermission.request() }
        }
        if !HotkeyManager.isProcessTrusted {
            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let settingsURL = URL(string: url) {
                NSWorkspace.shared.open(settingsURL)
            }
        }
    }
}
