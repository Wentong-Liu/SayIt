import AppKit
import SayItCore

/// 把 App 设为菜单栏代理：无 Dock 图标、不抢主窗口焦点。
/// 用运行时 `setActivationPolicy(.accessory)` 实现（配合 Info.plist 的 LSUIElement）。
///
/// 同时在启动时拉起端到端听写编排器 ``DictationCoordinator``（热键 → 录音 → 转写 → 润色 → 注入）。
///
/// 授权策略（避免启动即打扰）：
/// - 麦克风：未决定时静默弹系统对话框（无副作用、用户预期内的一次性请求）。
/// - 辅助功能：**不在启动时打开系统设置**；改由 ``DictationCoordinator`` 在用户首次按下听写键、
///   且发现未授权时再引导（按需、贴合意图）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 首次运行仅引导麦克风权限（系统对话框，用户预期内）。辅助功能改为按下听写键时按需引导。
        requestMicrophoneIfNeeded()

        // 启动端到端听写编排，把高层状态桥接到可观察持有者（菜单栏图标据此刷新）。
        DictationCoordinator.shared.onPhaseChange = { phase in
            DictationStatus.shared.phase = phase
        }
        DictationCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationCoordinator.shared.stop()
    }

    /// 麦克风：未决定时弹系统对话框请求（用户拒绝后由听写流程在 HUD 提示）。
    private func requestMicrophoneIfNeeded() {
        if MicrophonePermission.current == .notDetermined {
            Task { _ = await MicrophonePermission.request() }
        }
    }
}
