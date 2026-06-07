import AppKit

/// 全局热键管理器：监听系统级按键，按所选模式产出 `.start` / `.stop` 事件。
///
/// 支持两种模式（见 ``HotkeyMode``）：
/// - **hold-to-talk**：按住触发键说话（keyDown -> `.start`，keyUp -> `.stop`）。
/// - **toggle**：双击修饰键开始，再次双击结束。
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

    /// 判定 toggle 双击的两次按下最大间隔（秒）。
    public let doubleTapThreshold: TimeInterval

    // MARK: 事件输出

    /// 主线程事件回调（与 ``events`` 同时生效）。
    public var onEvent: ((HotkeyEvent) -> Void)?

    /// 事件异步序列，便于 `for await event in manager.events { ... }`。
    public let events: AsyncStream<HotkeyEvent>
    private let eventContinuation: AsyncStream<HotkeyEvent>.Continuation

    // MARK: 内部状态

    private var holdMachine = HoldStateMachine()
    private var toggleMachine: ToggleStateMachine

    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    /// 是否正在监听。
    public private(set) var isRunning = false

    // MARK: 初始化

    /// - Parameters:
    ///   - triggerKey: 触发键，默认右 ⌘。
    ///   - mode: 触发模式，默认按住说话。
    ///   - doubleTapThreshold: toggle 双击判定阈值（秒），默认 0.4。
    public init(
        triggerKey: TriggerKey = .default,
        mode: HotkeyMode = .holdToTalk,
        doubleTapThreshold: TimeInterval = 0.4
    ) {
        self.triggerKey = triggerKey
        self.mode = mode
        self.doubleTapThreshold = doubleTapThreshold
        self.toggleMachine = ToggleStateMachine(threshold: doubleTapThreshold)

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

        // toggle 模式用 .flagsChanged 捕捉修饰键的「按下」边沿。
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
        }
        // hold 模式用 .keyDown/.keyUp；普通键的 keyDown 还用于打断 toggle 的半个双击。
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
        case .toggle:
            // 仅认目标键的「按下」边沿：该键的修饰标志此刻被 set。
            // Fn/Globe 的物理 keyCode 不稳定，故对它只比对 .function 标志。
            let isModifierTrigger = key == .fnGlobe
                ? event.modifierFlags.contains(.function)
                : (event.keyCode == key.keyCode && event.modifierFlags.contains(key.modifierFlag))
            if isModifierTrigger {
                if let result = toggleMachine.registerPress(at: event.timestamp) {
                    emit(result)
                }
            } else if event.keyCode != key.keyCode {
                // 其它修饰键变化（如夹了 ⌘C）打断双击。
                toggleMachine.reset()
            }

        case .holdToTalk:
            handleHoldFlagsChanged(event, key: key)
        }
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
        case .toggle:
            // 任意普通键按下打断 toggle 的半个双击（避免「修饰键+键」被当成双击的一半）。
            toggleMachine.reset()
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
        toggleMachine.reset()
    }
}
