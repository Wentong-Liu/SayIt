import Foundation

/// 润色上下文：注入目标 App 信息，帮助模型判断语域（见设计 Spec 第 6.1.8 节）。
///
/// 例如目标 App 为 Xcode 时倾向技术 / 代码注释语气，Mail 时倾向邮件语气，
/// Slack 时倾向消息语气。仅作语气 / 格式参考，不改变第 6.1 节的硬约束。
public struct PolishContext: Equatable, Sendable {
    /// 当前前台 App 的显示名（如 "Xcode" / "Mail" / "Slack"）。无法获取时为 nil。
    public let appName: String?
    /// 当前前台 App 的 bundle 标识符（如 "com.apple.dt.Xcode"）。可选，用于更精确判断。
    public let bundleId: String?

    public init(appName: String? = nil, bundleId: String? = nil) {
        self.appName = appName
        self.bundleId = bundleId
    }
}
