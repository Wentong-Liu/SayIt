#if canImport(AppKit)
import AppKit

/// The shared NSPanel builder for the HUD floating panels (recording status + dictionary suggestion).
///
/// Both controllers create a borderless, non-focus-stealing floating panel with the exact same nine fields
/// (style mask, backing, level, opacity, background, shadow, movability, collection behavior); they differ only in
/// content size, whether mouse events are ignored, and the hosted content view. This factory owns the identical
/// fields so the two `buildPanel` methods cannot drift, while keeping the three real differences as parameters.
@MainActor
enum HUDPanelFactory {
    /// Builds a HUD panel with the shared configuration plus the three per-panel parameters.
    /// - Parameters:
    ///   - contentSize: the initial content size (each panel's own `Layout.initialSize`; relaid out by content after creation).
    ///   - ignoresMouseEvents: whether the panel ignores clicks — the recording HUD only displays (`true`),
    ///     the suggestion panel must accept Add/Dismiss clicks (`false`).
    ///   - contentView: the hosted content view (an `NSHostingView` wrapping the panel's SwiftUI root).
    static func makePanel(contentSize: NSSize, ignoresMouseEvents: Bool, contentView: NSView) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: contentSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = contentView
        return panel
    }
}
#endif
