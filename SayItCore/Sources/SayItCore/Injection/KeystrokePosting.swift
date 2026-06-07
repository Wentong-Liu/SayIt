import AppKit
import ApplicationServices

/// 模拟键盘事件的最小抽象，便于单测时注入桩、不真正向系统发键。
@MainActor
public protocol KeystrokePosting: Sendable {
    /// 模拟 ⌘V 粘贴。返回 keyDown/keyUp 两个 CGEvent 是否都成功创建并投递。
    func postPaste() -> Bool
}

/// 基于 CGEvent 的实现。参考 ZhiYu InserterProbe 的发键/键码/cghidEventTap 模式。
@MainActor
public final class CGEventKeystrokePoster: KeystrokePosting {
    /// 虚拟键码（macOS ANSI 键盘）：V。
    private static let keyCodeV: CGKeyCode = 9

    public init() {}

    /// 投递一对带 ⌘ flag 的 V keyDown/keyUp，模拟粘贴。
    /// CGEventSource / down / up 任一为 nil（系统未能建事件）时返回 false，粘贴未真正发出。
    public func postPaste() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: Self.keyCodeV, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: Self.keyCodeV, keyDown: false)
        guard let down, let up else {
            NSLog("[SayIt][TextInjector] postPaste 失败：CGEvent 创建为 nil(src=%@ down=%@ up=%@)，⌘V 未发出",
                  src == nil ? "nil" : "ok", down == nil ? "nil" : "ok", up == nil ? "nil" : "ok")
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
