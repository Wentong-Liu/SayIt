import AppKit

/// 提供「当前聚焦 App」的最小抽象，便于单测时注入桩。
@MainActor
public protocol FrontmostAppProviding: Sendable {
    /// 当前前台 App 的快照，无前台 App 时返回 nil。
    func captureTarget() -> InjectionTarget?
}

/// 基于 NSWorkspace.shared.frontmostApplication 的实现。
@MainActor
public final class WorkspaceFrontmostAppProvider: FrontmostAppProviding {
    public init() {}

    public func captureTarget() -> InjectionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InjectionTarget(running: app)
    }
}
