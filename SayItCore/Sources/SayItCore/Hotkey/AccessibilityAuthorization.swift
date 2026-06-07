#if canImport(AppKit)
import ApplicationServices
import AppKit

/// A `@MainActor`-safe wrapper for Accessibility authorization.
///
/// Both global hotkey monitoring and text injection depend on this authorization. The previously scattered global
/// `AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt)` calls are concurrency-unsafe
/// (`kAXTrustedCheckOptionPrompt` is a global `CFString` shared across isolation domains, unsafe under Swift 6 strict concurrency).
/// Here it is consolidated into one `@MainActor` type, so every entry point that touches that global symbol and System Settings runs serially on the main thread.
///
/// Usage:
/// - ``isTrusted``: a pure query, no prompt (equivalent to ``HotkeyManager/isProcessTrusted``).
/// - ``ensureTrusted(prompting:)``: when unauthorized, pops up the system authorization dialog (prompt) on demand; returns whether currently authorized.
/// - ``openSettings()``: opens System Settings > Privacy & Security > Accessibility.
@MainActor
public enum AccessibilityAuthorization {

    /// Whether the process has been granted Accessibility trust (no prompt, no side effect).
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// The global `kAXTrustedCheckOptionPrompt` (a `CFStringRef` global `var`) is judged concurrency-unsafe under Swift 6 strict concurrency.
    /// Its value is the stable public string `"AXTrustedCheckOptionPrompt"`,
    /// so here we build the key from a literal, bypassing a direct reference to that unsafe global symbol.
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt" as CFString

    /// Confirms whether authorized; when `prompting == true` and unauthorized, triggers the system's Accessibility authorization dialog.
    ///
    /// The entire call is consolidated on the `@MainActor`, using a local constant key instead of the unsafe global symbol.
    /// The return value is the trust state "after" the call (the prompt is an async system behavior, usually still false at this moment).
    /// - Parameter prompting: whether to pop up the system dialog to guide authorization when unauthorized.
    /// - Returns: whether currently trusted.
    @discardableResult
    public static func ensureTrusted(prompting: Bool) -> Bool {
        guard prompting else { return isTrusted }
        let options = [promptOptionKey: kCFBooleanTrue as Any] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings > Privacy & Security > Accessibility, guiding the user to enable it manually.
    public static func openSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
