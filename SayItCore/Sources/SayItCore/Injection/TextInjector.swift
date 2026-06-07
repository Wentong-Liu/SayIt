import AppKit
import ApplicationServices

/// 把文本注入当前聚焦 App 光标处的默认实现。
///
/// 策略：
/// 1. 捕获目标 App（NSWorkspace.shared.frontmostApplication）。
/// 2. 若启用 AX 增强路径且已授权，先尝试 AXUIElementSetAttributeValue 直接插入；成功即返回。
/// 3. 否则走默认剪贴板路径：保存当前剪贴板 → 写入文本 → 模拟 ⌘V → 延迟后还原原剪贴板。
/// 4. 任一路径失败时，文本保留在剪贴板并返回 .failedTextLeftInPasteboard，便于用户手动粘贴。
///
/// 依赖全部通过协议注入，关键纯逻辑（剪贴板保存/还原、目标 App 捕获）可单测。
@MainActor
public final class TextInjector: TextInjecting {
    /// 行为可调参数。
    public struct Configuration: Sendable {
        /// 是否优先尝试 AX 直接插入（增强路径）。默认 false：剪贴板粘贴更通用、兼容性更好。
        public var preferAccessibility: Bool
        /// ⌘V 投递后、还原剪贴板前的等待时长。给目标 App 留出读取剪贴板的时间。
        public var restoreDelay: Duration

        public init(preferAccessibility: Bool = false,
                    restoreDelay: Duration = .milliseconds(150)) {
            self.preferAccessibility = preferAccessibility
            self.restoreDelay = restoreDelay
        }

        public static let `default` = Configuration()
    }

    private let configuration: Configuration
    private let pasteboard: PasteboardProtocol
    private let keystroke: KeystrokePosting
    private let frontmostProvider: FrontmostAppProviding
    private let axInserter: AXTextInserting
    /// 等待实现：默认基于 Task.sleep，单测可注入即时返回的桩以免拖慢测试。
    private let sleeper: @Sendable (Duration) async -> Void

    public init(
        configuration: Configuration = .default,
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        keystroke: KeystrokePosting = CGEventKeystrokePoster(),
        frontmostProvider: FrontmostAppProviding = WorkspaceFrontmostAppProvider(),
        axInserter: AXTextInserting = AXTextInserter(),
        sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.frontmostProvider = frontmostProvider
        self.axInserter = axInserter
        self.sleeper = sleeper
    }

    /// 同步注入入口（协议要求）。空文本无操作；其余转交内部实现。
    /// 还原剪贴板需要在 ⌘V 之后延迟执行，这里把延迟+还原放进 detached 之外的
    /// 当前 actor 的异步任务里，调用方拿到结果时粘贴已投递、还原稍后完成。
    public func inject(_ text: String) -> InjectionResult {
        guard !text.isEmpty else { return .success(method: .pasteboard) }

        guard let target = frontmostProvider.captureTarget() else {
            // 无前台 App：仍把文本放进剪贴板，方便用户手动粘贴。
            pasteboard.writeString(text)
            return .failedTextLeftInPasteboard(reason: "无前台 App，无法定位注入目标")
        }

        // 增强路径：AX 直接插入。成功即不动剪贴板。
        if configuration.preferAccessibility {
            if axInserter.insert(text, into: target) {
                return .success(method: .accessibility)
            }
            // AX 失败则继续走剪贴板回退（不直接判失败）。
        }

        return injectViaPasteboard(text)
    }

    /// 剪贴板粘贴路径：保存 → 写入 → ⌘V → 延迟还原。
    private func injectViaPasteboard(_ text: String) -> InjectionResult {
        let backup = PasteboardBackup.capture(from: pasteboard)
        pasteboard.writeString(text)

        let posted = keystroke.postPaste()
        guard posted else {
            // ⌘V 没发出去：不还原，文本留在剪贴板供用户手动粘贴。
            return .failedTextLeftInPasteboard(reason: "模拟 ⌘V 失败，文本已留在剪贴板")
        }

        // 延迟后还原原剪贴板，给目标 App 读取剪贴板的时间。
        // 用 Task 异步执行，避免阻塞调用方；粘贴此刻已投递。
        scheduleRestore(backup)
        return .success(method: .pasteboard)
    }

    /// 延迟还原剪贴板。
    private func scheduleRestore(_ backup: PasteboardBackup) {
        let delay = configuration.restoreDelay
        let pb = pasteboard
        let sleep = sleeper
        Task { @MainActor in
            await sleep(delay)
            backup.restore(to: pb)
        }
    }
}
