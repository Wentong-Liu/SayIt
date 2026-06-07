import AppKit

/// 把 App 设为菜单栏代理：无 Dock 图标、不抢主窗口焦点。
/// 用运行时 `setActivationPolicy(.accessory)` 实现（配合 Info.plist 的 LSUIElement）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
