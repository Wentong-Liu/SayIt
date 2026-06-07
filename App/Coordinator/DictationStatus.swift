import Observation
import SayItCore

/// 听写高层状态的可观察持有者：把 ``DictationCoordinator`` 的 `phase` 桥接到 SwiftUI（菜单栏图标）。
///
/// 编排器为 `@MainActor`、回调在主线程触发，故此类型亦 `@MainActor`，UI 直接读 `phase` 即可响应。
@MainActor
@Observable
final class DictationStatus {
    /// 进程级共享实例：``AppDelegate`` 写、``SayItApp`` 读。
    static let shared = DictationStatus()

    /// 当前听写阶段（idle / listening / working）。
    var phase: DictationCoordinator.Phase = .idle

    init() {}
}
