import Foundation

/// 听写会话的边沿事件，由热键状态机产出、向上传递。
public enum HotkeyEvent: Equatable, Sendable {
    /// 开始录音/听写。
    case start
    /// 结束录音/听写。
    case stop
}

/// 两种触发模式。
public enum HotkeyMode: String, CaseIterable, Sendable {
    /// 按住触发键说话：keyDown -> start，keyUp -> stop。
    case holdToTalk
    /// 双击修饰键开始、再次双击结束。
    case toggle
}

// MARK: - 双击判定（纯逻辑）

/// 「双击」判定的纯状态机：连续两次按下若间隔 ≤ 阈值则判为一次双击。
///
/// 不依赖时钟——调用方传入事件时间戳（如 `NSEvent.timestamp`，单位秒），
/// 因此可在单测里用确定性的时间序列覆盖阈值边界。
public struct DoubleTapDetector: Sendable {
    /// 两次按下被判为「双击」的最大间隔（秒，含端点）。
    public let threshold: TimeInterval
    /// 上一次「待配对」按下的时间戳；nil 表示当前没有半个双击在等待。
    private var pendingPressTimestamp: TimeInterval?

    public init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    /// 登记一次「按下」。
    /// - Returns: 若与上一次按下构成阈值内的双击则返回 `true`（并清空内部状态，下次重新计）；否则 `false`。
    public mutating func registerPress(at timestamp: TimeInterval) -> Bool {
        if let previous = pendingPressTimestamp, timestamp - previous <= threshold {
            pendingPressTimestamp = nil
            return true
        }
        // 首次按下，或超出阈值：把本次当作新的「首次按下」等待配对。
        pendingPressTimestamp = timestamp
        return false
    }

    /// 作废当前等待配对的首次按下（例如夹了其它按键，打断双击）。
    public mutating func reset() {
        pendingPressTimestamp = nil
    }
}

// MARK: - toggle 模式状态机（纯逻辑）

/// toggle 模式：双击 -> start，再次双击 -> stop，如此交替。
///
/// 在 `DoubleTapDetector` 之上维护「会话是否激活」的开关。
public struct ToggleStateMachine: Sendable {
    private var detector: DoubleTapDetector
    /// 会话是否处于激活（录音中）状态。
    private var isActive = false

    public init(threshold: TimeInterval) {
        self.detector = DoubleTapDetector(threshold: threshold)
    }

    /// 登记一次目标键的「按下」边沿。
    /// - Returns: 构成双击时返回对应的 `.start` / `.stop`；否则返回 nil。
    public mutating func registerPress(at timestamp: TimeInterval) -> HotkeyEvent? {
        guard detector.registerPress(at: timestamp) else { return nil }
        isActive.toggle()
        return isActive ? .start : .stop
    }

    /// 打断「半个双击」（如夹了其它按键）。不改变会话激活状态。
    public mutating func reset() {
        detector.reset()
    }
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
