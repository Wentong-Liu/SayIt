#if canImport(AppKit)
import ApplicationServices
import AppKit

/// 「辅助功能」（Accessibility）授权的 `@MainActor` 安全封装。
///
/// 全局热键监听与文本注入都依赖此项授权。过去散落的全局
/// `AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt)` 调用是 concurrency-unsafe 的
/// （`kAXTrustedCheckOptionPrompt` 是个跨隔离域共享的全局 `CFString`，在 Swift6 严格并发下不安全）。
/// 这里把它收敛进一个 `@MainActor` 类型，所有触碰该全局符号与系统设置的入口都在主线程串行进行。
///
/// 用法：
/// - ``isTrusted``：纯查询，不弹窗（等价于 ``HotkeyManager/isProcessTrusted``）。
/// - ``ensureTrusted(prompting:)``：未授权时按需弹出系统授权对话框（prompt）；返回当前是否已授权。
/// - ``openSettings()``：打开「系统设置 › 隐私与安全性 › 辅助功能」。
@MainActor
public enum AccessibilityAuthorization {

    /// 进程是否已获得「辅助功能」信任（不弹窗、无副作用）。
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 全局 `kAXTrustedCheckOptionPrompt`（一个 `CFStringRef` 全局 `var`）在 Swift6 严格并发下
    /// 被判为 concurrency-unsafe。其值是稳定的公开字符串 `"AXTrustedCheckOptionPrompt"`，
    /// 这里用字面量自建键，绕开对该不安全全局符号的直接引用。
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt" as CFString

    /// 确认是否已授权；`prompting == true` 且未授权时，触发系统的辅助功能授权对话框。
    ///
    /// 整个调用收敛在 `@MainActor`，并用本地常量键替代不安全的全局符号。
    /// 返回值为「调用后」的信任状态（弹窗为异步系统行为，通常此刻仍为 false）。
    /// - Parameter prompting: 未授权时是否弹出系统对话框引导授权。
    /// - Returns: 当前是否已被信任。
    @discardableResult
    public static func ensureTrusted(prompting: Bool) -> Bool {
        guard prompting else { return isTrusted }
        let options = [promptOptionKey: kCFBooleanTrue as Any] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 打开「系统设置 › 隐私与安全性 › 辅助功能」，引导用户手动开启。
    public static func openSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
