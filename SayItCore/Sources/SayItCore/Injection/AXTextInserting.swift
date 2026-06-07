import AppKit
import ApplicationServices

/// 通过 Accessibility 直接把文本插入聚焦元素的最小抽象，便于单测注入桩。
@MainActor
public protocol AXTextInserting: Sendable {
    /// 是否已被授予辅助功能权限。
    var isTrusted: Bool { get }
    /// 把 text 插入到目标 App 当前聚焦元素的光标处。返回是否成功。
    func insert(_ text: String, into target: InjectionTarget) -> Bool
}

/// 基于 AXUIElement 的实现（增强路径）。
/// 优先在聚焦元素的当前选区/光标处插入（设 AXSelectedText，行为类似输入）；
/// 不支持选区时回退为整体替换 AXValue。
@MainActor
public final class AXTextInserter: AXTextInserting {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func insert(_ text: String, into target: InjectionTarget) -> Bool {
        guard isTrusted else { return false }
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        guard let focused = copyFocusedElement(of: appElement) else { return false }

        // 1) 首选：把选区文本替换成 text。等价于在光标处插入（无选区时即插入），
        //    可保留输入框已有内容，比整体覆盖 AXValue 更接近真实输入。
        let setSelected = AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFString
        )
        if setSelected == .success { return true }

        // 2) 回退：整体替换 AXValue（仅当元素支持可写 AXValue）。
        guard isValueSettable(focused) else { return false }
        let setValue = AXUIElementSetAttributeValue(
            focused, kAXValueAttribute as CFString, text as CFString
        )
        return setValue == .success
    }

    /// 读取 App 的当前聚焦 UI 元素。
    private func copyFocusedElement(of appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &value
        )
        guard err == .success, let value else { return nil }
        // value 是一个 AXUIElement（CFType）。
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// AXValue 是否可写（不可写时设值会失败，提前判断避免无谓尝试）。
    private func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable
        )
        return err == .success && settable.boolValue
    }
}
