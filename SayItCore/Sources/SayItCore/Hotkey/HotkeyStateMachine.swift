import Foundation

/// 听写会话的边沿事件，由热键状态机产出、向上传递。
public enum HotkeyEvent: Equatable, Sendable {
    /// 开始录音/听写。
    case start
    /// 结束录音/听写。
    case stop
}

/// 触发模式。
public enum HotkeyMode: String, CaseIterable, Sendable {
    /// 按住触发键说话：keyDown -> start，keyUp -> stop。
    case holdToTalk
    /// 单击（孤立轻点）修饰键开始、再次单击结束。
    ///
    /// 「孤立轻点」= 修饰键按下后**没有夹任何普通键**、并在短窗口内松开（见 ``IsolatedTapDetector``）。
    /// 这让单击触发不与普通快捷键（如 ⌘C）冲突。对应 Typeless / 闪电说 的交互。
    case singleTapToggle
}

// MARK: - hold-to-talk 模式状态机（纯逻辑）

/// hold-to-talk 模式：按下触发键 -> start，松开 -> stop。
///
/// 处理系统按键自动重复（连续多个 keyDown）与异常序列（无 down 的 up）。
public struct HoldStateMachine: Sendable {
    /// 当前是否处于「按住中」。
    private var isHeld = false

    public init() {}

    /// 登记触发键「按下」。
    /// - Returns: 由未按住转为按住时返回 `.start`；自动重复的后续 keyDown 返回 nil。
    public mutating func keyDown() -> HotkeyEvent? {
        guard !isHeld else { return nil }
        isHeld = true
        return .start
    }

    /// 登记触发键「松开」。
    /// - Returns: 由按住转为松开时返回 `.stop`；未处于按住状态则返回 nil。
    public mutating func keyUp() -> HotkeyEvent? {
        guard isHeld else { return nil }
        isHeld = false
        return .stop
    }

    /// 清空按住状态，且不产出任何事件（例如监听重启、焦点丢失时强制复位）。
    public mutating func reset() {
        isHeld = false
    }
}

// MARK: - 孤立轻点判定（纯逻辑）

/// 「孤立轻点（isolated tap）」判定的纯状态机：识别一次**单独**的修饰键轻点。
///
/// 触发条件（三者皆需）：
/// 1. 修饰键按下（`modifierDown`）后松开（`modifierUp`）；
/// 2. 这期间**没有任何普通（非修饰）键**按下——否则是组合键（如 ⌘C），不算轻点；
/// 3. 按下到松开的间隔 ≤ ``window``（默认 ~0.3s）——长按不算轻点（留给 hold 模式或避免误触）。
///
/// 这正是 Typeless（轻点 ⌥）/ 闪电说（轻点 ⌘）的标准做法，能让单击触发与系统快捷键并存：
/// 夹了别的键就当普通快捷键放过，不触发听写。
///
/// 不依赖时钟——调用方传入事件时间戳（如 `NSEvent.timestamp`，单位秒），故单测可用确定性
/// 时间序列覆盖窗口边界。
public struct IsolatedTapDetector: Sendable {
    /// 按下到松开判为「轻点」的最大间隔（秒，含端点）。超出视为长按，不算轻点。
    public let window: TimeInterval

    /// 修饰键按下的时间戳；nil 表示当前修饰键未按下（没有进行中的候选轻点）。
    private var pressTimestamp: TimeInterval?
    /// 本次按住期间是否被「夹了普通键」污染（一旦污染则松开不判为轻点）。
    private var contaminated = false

    /// - Parameter window: 轻点时间窗口（秒），默认 0.3s。
    public init(window: TimeInterval = 0.3) {
        self.window = window
    }

    /// 登记修饰键「按下」边沿，开始一次候选轻点。
    ///
    /// 自动重复（修饰键按住时系统不重复发 flagsChanged，但保险起见）：已在按下中则忽略，
    /// 保留首次按下的时间戳与污染状态。
    public mutating func modifierDown(at timestamp: TimeInterval) {
        guard pressTimestamp == nil else { return }
        pressTimestamp = timestamp
        contaminated = false
    }

    /// 登记修饰键「松开」边沿。
    /// - Returns: 满足孤立轻点三条件时返回 `true`（并复位，下次重新计）；否则 `false`。
    public mutating func modifierUp(at timestamp: TimeInterval) -> Bool {
        defer { reset() }
        guard let press = pressTimestamp, !contaminated else { return false }
        return timestamp - press <= window
    }

    /// 登记一次普通（非修饰）键按下，污染当前候选轻点（之后松开不再判为轻点）。
    /// 仅在修饰键正按下时有意义；未按下时调用无副作用。
    public mutating func otherKeyDown() {
        guard pressTimestamp != nil else { return }
        contaminated = true
    }

    /// 复位：作废进行中的候选轻点（例如监听重启、焦点丢失）。
    public mutating func reset() {
        pressTimestamp = nil
        contaminated = false
    }
}

// MARK: - 单击切换状态机（纯逻辑）

/// single-tap-to-toggle 模式：一次孤立轻点 -> start，再一次 -> stop，如此交替。
///
/// 在 ``IsolatedTapDetector`` 之上维护「会话是否激活（录音中）」开关。
public struct SingleTapToggleStateMachine: Sendable {
    private var detector: IsolatedTapDetector
    /// 会话是否处于激活（录音中）状态。
    private var isActive = false

    /// - Parameter window: 轻点时间窗口（秒），默认 0.3s。
    public init(window: TimeInterval = 0.3) {
        self.detector = IsolatedTapDetector(window: window)
    }

    /// 登记修饰键按下边沿（开始一次候选轻点）。本身不产出事件。
    public mutating func modifierDown(at timestamp: TimeInterval) {
        detector.modifierDown(at: timestamp)
    }

    /// 登记修饰键松开边沿。
    /// - Returns: 构成孤立轻点时返回 `.start` / `.stop`（交替）；否则 nil。
    public mutating func modifierUp(at timestamp: TimeInterval) -> HotkeyEvent? {
        guard detector.modifierUp(at: timestamp) else { return nil }
        isActive.toggle()
        return isActive ? .start : .stop
    }

    /// 普通键按下：污染当前候选轻点（之后松开不触发），不改变会话激活状态。
    public mutating func otherKeyDown() {
        detector.otherKeyDown()
    }

    /// 复位进行中的候选轻点；不改变会话激活状态。
    public mutating func reset() {
        detector.reset()
    }
}
