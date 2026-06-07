import AppKit

/// 全局热键管理器：监听系统级按键，按所选模式产出 `.start` / `.stop` 事件。
///
/// 支持两种模式（见 ``HotkeyMode``）：
/// - **hold-to-talk**：按住触发键说话（keyDown -> `.start`，keyUp -> `.stop`）。
/// - **single-tap-to-toggle**：孤立轻点修饰键开始，再次轻点结束（默认）。「孤立轻点」=
///   修饰键按下→松开且中途没夹普通键、在短窗口内完成，故不与 ⌘C 等快捷键冲突。
///
/// 事件以两种方式对外发出，二者同时生效：
/// - 回调 ``onEvent``（在主线程调用）；
/// - 异步序列 ``events``（`AsyncStream`，便于 `for await` 消费）。
///
/// ## 所需系统权限
/// 全局监听其它 app 的按键属于敏感操作，macOS 需要用户授权，二者按使用的 API 取其一或并需：
/// - **辅助功能（Accessibility）**：系统设置 › 隐私与安全性 › 辅助功能。
///   `NSEvent.addGlobalMonitorForEvents` 监听 `.keyDown` / `.keyUp` 通常需要此项。
/// - **输入监控（Input Monitoring）**：系统设置 › 隐私与安全性 › 输入监控。
///   若改用 `CGEventTap` 截获按键，则需要此项。
///
/// 本实现采用 `NSEvent` 全局监听（不截获、不阻断事件，仅观察），优先依赖「辅助功能」授权。
/// 未授权时监听器会被创建但收不到回调——调用方应先用 ``isProcessTrusted`` 检查并引导用户授权。
///
/// 该类型为 `@MainActor`：`NSEvent` 监听 API 须在主线程使用，状态也仅在主线程读写。
@MainActor
public final class HotkeyManager {

    // MARK: 配置

    /// 当前触发键。改值后下一次事件即生效；监听回调里实时读取，无需重启监听。
    public var triggerKey: TriggerKey

    /// 当前模式。改值后会复位内部状态机，避免跨模式残留。
    public var mode: HotkeyMode {
        didSet {
            guard oldValue != mode else { return }
            resetStateMachines()
        }
    }

    /// single-tap 模式判定「孤立轻点」的按下→松开最大间隔（秒）。
    public let singleTapWindow: TimeInterval

    // MARK: 事件输出

    /// 主线程事件回调（与 ``events`` 同时生效）。
    public var onEvent: ((HotkeyEvent) -> Void)?

    /// 事件异步序列，便于 `for await event in manager.events { ... }`。
    public let events: AsyncStream<HotkeyEvent>
    private let eventContinuation: AsyncStream<HotkeyEvent>.Continuation

    // MARK: 内部状态

    private var holdMachine = HoldStateMachine()
    private var singleTapMachine: SingleTapToggleStateMachine

    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    /// 是否正在监听。
    public private(set) var isRunning = false

    // MARK: 初始化

    /// - Parameters:
    ///   - triggerKey: 触发键，默认右 ⌘。
    ///   - mode: 触发模式，默认单击切换。
    ///   - singleTapWindow: single-tap 孤立轻点按下→松开窗口（秒），默认 0.3。
    public init(
        triggerKey: TriggerKey = .default,
        mode: HotkeyMode = .singleTapToggle,
        singleTapWindow: TimeInterval = 0.3
    ) {
        self.triggerKey = triggerKey
        self.mode = mode
        self.singleTapWindow = singleTapWindow
        self.singleTapMachine = SingleTapToggleStateMachine(window: singleTapWindow)

        var continuation: AsyncStream<HotkeyEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: 权限

    /// 进程是否已获得「辅助功能」信任（全局键盘监听的前置条件）。
    ///
    /// 返回 `false` 时，应引导用户到「系统设置 › 隐私与安全性 › 辅助功能」勾选本 app，
    /// 否则全局监听虽能建立但收不到事件。
    public static var isProcessTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 同上，实例便捷访问。
    public var isProcessTrusted: Bool { Self.isProcessTrusted }

    // MARK: 启停

    /// 开始全局监听。重复调用是幂等的。
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        resetStateMachines()

        // 触发键为修饰键，其按下/松开走 .flagsChanged。
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
        }
        // 普通键的 keyDown 用于污染 single-tap 的候选轻点（夹了快捷键不触发）。
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyDown(event) }
        }
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyUp(event) }
        }
    }

    /// 停止监听并移除所有系统监视器。重复调用是幂等的。
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        for monitor in [flagsMonitor, keyDownMonitor, keyUpMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        flagsMonitor = nil
        keyDownMonitor = nil
        keyUpMonitor = nil
        resetStateMachines()
    }

    // MARK: 事件处理（壳层 -> 纯状态机）

    private func handleFlagsChanged(_ event: NSEvent) {
        let key = triggerKey

        switch mode {
        case .singleTapToggle:
            handleSingleTapFlagsChanged(event, key: key)

        case .holdToTalk:
            handleHoldFlagsChanged(event, key: key)
        }
    }

    /// single-tap 模式下，触发键的按下/松开走 `.flagsChanged`（修饰键不发 keyDown/keyUp）。
    /// 按下开始候选轻点，松开时由状态机判定是否构成孤立轻点（中途夹普通键由 `handleKeyDown` 污染）。
    private func handleSingleTapFlagsChanged(_ event: NSEvent, key: TriggerKey) {
        if isTriggerPressEdge(event, key: key) {
            singleTapMachine.modifierDown(at: event.timestamp)
        } else if key == .fnGlobe || event.keyCode == key.keyCode {
            // 目标键的松开边沿（标志被清）。
            if let result = singleTapMachine.modifierUp(at: event.timestamp) {
                emit(result)
            }
        } else {
            // 另一修饰键按下/松开（如同时按了 ⌘＋⌥）：视为夹了别的键，作废本次候选轻点。
            singleTapMachine.otherKeyDown()
        }
    }

    /// 判断本次 `.flagsChanged` 是否为触发键的「按下」边沿（该键的修饰标志此刻被 set）。
    /// Fn/Globe 的物理 keyCode 不稳定，故对它只比对 `.function` 标志。
    private func isTriggerPressEdge(_ event: NSEvent, key: TriggerKey) -> Bool {
        key == .fnGlobe
            ? event.modifierFlags.contains(.function)
            : (event.keyCode == key.keyCode && event.modifierFlags.contains(key.modifierFlag))
    }

    /// hold 模式下，若触发键本身是修饰键，其按下/松开走 `.flagsChanged`（修饰键不发 keyDown/keyUp）。
    private func handleHoldFlagsChanged(_ event: NSEvent, key: TriggerKey) {
        let isPressed: Bool = key == .fnGlobe
            ? event.modifierFlags.contains(.function)
            : (event.keyCode == key.keyCode && event.modifierFlags.contains(key.modifierFlag))

        if isPressed {
            if let result = holdMachine.keyDown() { emit(result) }
        } else if key == .fnGlobe || event.keyCode == key.keyCode {
            // 目标键的松开边沿（标志被清）。
            if let result = holdMachine.keyUp() { emit(result) }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        switch mode {
        case .singleTapToggle:
            // 修饰键按住期间按了普通键（如 ⌘C）：污染本次候选轻点，松开不再触发 -> 让位给快捷键。
            singleTapMachine.otherKeyDown()
        case .holdToTalk:
            // 触发键为修饰键时由 .flagsChanged 处理；此处仅处理非修饰触发键（预留扩展）。
            break
        }
    }

    private func handleKeyUp(_ event: NSEvent) {
        // 当前触发键均为修饰键，松开走 .flagsChanged；普通键的 keyUp 暂无需处理（预留扩展）。
    }

    // MARK: 工具

    private func emit(_ event: HotkeyEvent) {
        onEvent?(event)
        eventContinuation.yield(event)
    }

    private func resetStateMachines() {
        holdMachine.reset()
        singleTapMachine.reset()
    }
}
