import AppKit
import ApplicationServices

/// A minimal abstraction for inserting text directly into the focused element via Accessibility, to allow injecting stubs in unit tests.
@MainActor
public protocol AXTextInserting: Sendable {
    /// Whether accessibility permission has been granted.
    var isTrusted: Bool { get }
    /// Inserts text at the cursor of the target App's current focused element. Returns whether it succeeded.
    func insert(_ text: String, into target: InjectionTarget) -> Bool
}

/// Implementation based on AXUIElement (enhanced path).
/// Prefers inserting at the focused element's current selection/cursor (sets AXSelectedText, behaving like typing);
/// when selection is unsupported, falls back to replacing AXValue wholesale.
@MainActor
public final class AXTextInserter: AXTextInserting {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func insert(_ text: String, into target: InjectionTarget) -> Bool {
        guard isTrusted else { return false }
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        guard let focused = copyFocusedElement(of: appElement) else { return false }

        // 1) Preferred: replace the selection text with text. Equivalent to inserting at the cursor (an insert when there is no selection),
        //    which preserves existing content in the input field and is closer to real typing than overwriting AXValue wholesale.
        let setSelected = AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFString
        )
        if setSelected == .success { return true }

        // 2) Fallback: replace AXValue wholesale (only when the element supports a writable AXValue).
        guard isValueSettable(focused) else { return false }
        let setValue = AXUIElementSetAttributeValue(
            focused, kAXValueAttribute as CFString, text as CFString
        )
        return setValue == .success
    }

    /// Reads the App's current focused UI element.
    private func copyFocusedElement(of appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &value
        )
        guard err == .success, let value else { return nil }
        // value is an AXUIElement (CFType).
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Whether AXValue is writable (setting a value fails when it is not, so check ahead to avoid a pointless attempt).
    private func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable
        )
        return err == .success && settable.boolValue
    }
}
