import AppKit
import ApplicationServices

/// A minimal abstraction for simulating keyboard events, to allow injecting stubs in unit tests without sending real keys to the system.
@MainActor
public protocol KeystrokePosting: Sendable {
    /// Simulates a Cmd-V paste. Returns whether both the keyDown/keyUp CGEvents were successfully created and delivered.
    func postPaste() -> Bool
}

/// Implementation based on CGEvent. Refers to ZhiYu's InserterProbe key-sending/keycode/cghidEventTap pattern.
@MainActor
public final class CGEventKeystrokePoster: KeystrokePosting {
    /// Virtual keycode (macOS ANSI keyboard): V.
    private static let keyCodeV: CGKeyCode = 9

    public init() {}

    /// Delivers a pair of V keyDown/keyUp with the Cmd flag set, simulating a paste.
    /// Returns false if any of CGEventSource / down / up is nil (the system failed to build the event), meaning the paste was not actually sent.
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
