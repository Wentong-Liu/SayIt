import AppKit
import ApplicationServices
import Carbon

/// A snapshot of the system-wide focused element's text and selection, as read via Accessibility.
///
/// `CFRange` is neither `Sendable` nor `Equatable`, so the selection is flattened to two optional `Int`s
/// (`selectedLocation` / `selectedLength`) to keep this value type cleanly `Sendable` + `Equatable`.
public struct FocusedText: Sendable, Equatable {
    /// The full current text of the focused element (`kAXValueAttribute`).
    public let value: String
    /// The caret/selection start offset, or `nil` when the selection range is unreadable.
    public let selectedLocation: Int?
    /// The selection length (`0` for a bare caret), or `nil` when the selection range is unreadable.
    public let selectedLength: Int?

    public init(value: String, selectedLocation: Int?, selectedLength: Int?) {
        self.value = value
        self.selectedLocation = selectedLocation
        self.selectedLength = selectedLength
    }
}

/// A minimal abstraction for reading the system-wide focused element's text, to allow injecting stubs in unit tests
/// (the concrete reader needs a live UI / focused field, which is not available in a headless test run).
///
/// Mirrors the ``AXTextInserting`` shape used for the injection side: a trust flag plus one read entry point.
@MainActor
public protocol FocusedTextReading: Sendable {
    /// Whether accessibility permission has been granted (a prerequisite for reading any element).
    var isTrusted: Bool { get }
    /// Reads the current text + selection of the system-wide focused UI element. Returns `nil` on any failure.
    func readFocusedText() -> FocusedText?
}

/// Reads the system-wide focused element's value + selected range via Accessibility, degrading to `nil` on any failure.
///
/// This is the "read" counterpart to ``AXTextInserter`` and reuses the exact same AX primitives
/// (`AXUIElementCreateSystemWide` + `kAXFocusedUIElementAttribute` + `kAXValueAttribute` + `kAXSelectedTextRangeAttribute`).
/// It is the reader half of the "learn from edits" feature (Part B): the coordinator calls it right after an inject (to
/// confirm the field is readable) and again when editing is done, then sends the (injected, final) pair to the
/// ``LearnedTermExtracting`` LLM seam to extract the single corrected term.
///
/// Robustness contract — it returns `nil` (never crashes, never guesses) when:
/// - Secure Input is active (password/secure fields) — checked via `IsSecureEventInputEnabled()`;
/// - Accessibility is not trusted;
/// - there is no focused element, or it is not an `AXUIElement`;
/// - the element exposes no readable string value (web / Electron / terminal views typically do not).
///   The selection range is best-effort: if it is unreadable the read still succeeds with `nil` location/length.
@MainActor
public final class AXTextReader: FocusedTextReading {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func readFocusedText() -> FocusedText? {
        // Skip entirely when a secure input field is active — we must never read password / secure-field contents.
        guard !IsSecureEventInputEnabled() else { return nil }
        guard isTrusted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = copyFocusedElement(of: systemWide) else { return nil }
        guard let value = copyStringValue(focused) else { return nil }

        // The selection range is optional: an unreadable range must not fail the whole read.
        let range = copySelectedRange(focused)
        return FocusedText(value: value,
                           selectedLocation: range.map { $0.location },
                           selectedLength: range.map { $0.length })
    }

    // MARK: - AX helpers (each returns an optional and never crashes)

    /// Reads the system-wide focused UI element. Guards the CFType id before the force cast (same pattern as `AXTextInserter`).
    private func copyFocusedElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, kAXFocusedUIElementAttribute as CFString, &value
        )
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Reads the focused element's `kAXValueAttribute` as a `String`. Returns `nil` for non-string / absent values
    /// — exactly the graceful degradation needed for web / Electron / terminal elements that expose no usable value.
    private func copyStringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        )
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    /// Reads the focused element's `kAXSelectedTextRangeAttribute` and extracts the `CFRange` via `AXValueGetValue`.
    /// Returns `nil` when the attribute is absent or not an `AXValue` of `.cfRange` — the caller treats this as
    /// "selection unknown", not a hard failure.
    private func copySelectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        )
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
}
