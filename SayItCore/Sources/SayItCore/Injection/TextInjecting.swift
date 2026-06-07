import AppKit

/// 文本注入的目标 App 快照。注入前捕获，注入失败回退时可用于诊断/日志。
public struct InjectionTarget: Sendable, Equatable {
    /// 目标 App 的 bundle identifier（可能为 nil，例如某些无 bundle 的进程）。
    public let bundleIdentifier: String?
    /// 目标 App 的本地化名（可能为 nil）。
    public let localizedName: String?
    /// 目标 App 的进程 ID。
    public let processIdentifier: pid_t

    public init(bundleIdentifier: String?, localizedName: String?, processIdentifier: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.processIdentifier = processIdentifier
    }

    /// 从 NSRunningApplication 捕获快照。
    public init(running app: NSRunningApplication) {
        self.bundleIdentifier = app.bundleIdentifier
        self.localizedName = app.localizedName
        self.processIdentifier = app.processIdentifier
    }
}

/// 注入采用的路径。
public enum InjectionMethod: Sendable, Equatable {
    /// 通过 Accessibility 直接把文本写进聚焦元素（增强路径）。
    case accessibility
    /// 通过剪贴板写入并模拟 ⌘V 粘贴（默认路径）。
    case pasteboard
}

/// 注入结果。
public enum InjectionResult: Sendable, Equatable {
    /// 注入成功。method 表示最终生效的路径。
    case success(method: InjectionMethod)
    /// 注入失败，但文本已保留在剪贴板（用户可手动粘贴）。
    /// reason 为人类可读的失败原因。
    case failedTextLeftInPasteboard(reason: String)
}

extension InjectionResult {
    /// 是否注入成功。
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// 把一段文本注入到当前聚焦 App 的光标处。
public protocol TextInjecting: Sendable {
    /// 注入文本。返回注入结果；失败时文本会保留在剪贴板。
    /// - Parameter text: 要注入的文本。空串视为无操作并返回成功。
    @MainActor
    func inject(_ text: String) -> InjectionResult
}
