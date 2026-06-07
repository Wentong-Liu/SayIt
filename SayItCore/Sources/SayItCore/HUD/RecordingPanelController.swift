#if canImport(AppKit)
import AppKit
import SwiftUI

/// The controller for the dictation-status HUD: manages a borderless, non-focus-stealing floating panel, showing "listening / transcribing / error".
///
/// Panel characteristics:
/// - `NSPanel(.borderless, .nonactivatingPanel)`, level `.floating`, transparent background, no shadow border
///   (the shadow is self-drawn by the SwiftUI card, with the transparent outer margin `shadowPad` leaving rendering space).
/// - `.nonactivatingPanel` does not steal foreground focus; when the HUD pops up the user is still typing in the original app.
/// - The content uses SwiftUI (`RecordingPanelView`) wrapped via `NSHostingView`.
///
/// Positioning: defaults to the lower-center of the screen; when the caller passes a cursor point, it instead floats above the cursor. Both are clamped into the visible region
/// via `HUDPositioning.clamped`.
///
/// Lifecycle API: `show(state:near:)` / `update(state:)` / `update(level:)` / `hide()`.
/// Passing `.idle` is equivalent to `hide()` (does not display).
@MainActor
public final class RecordingPanelController {
    /// Process-level shared instance (the HUD is globally unique).
    public static let shared = RecordingPanelController()

    /// Panel layout constants.
    private enum Layout {
        /// Lower-center screen anchor: the spacing of the bottom edge from the bottom of the visible region.
        static let bottomMargin: CGFloat = 80
        /// Above-cursor anchor: the spacing of the HUD's bottom edge from the cursor point.
        static let cursorGap: CGFloat = 24
        /// The initial size when creating a new panel (relaid out by content right after creation).
        static let initialSize = NSSize(width: 160, height: 56)
        /// Fallback rect when the screen's visibleFrame cannot be obtained.
        static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        /// Fallback when the main screen height cannot be obtained (the CG/AppKit global y-flip baseline).
        static let fallbackPrimaryHeight: CGFloat = 1000
    }

    private var panel: NSPanel?
    private let model = RecordingPanelModel()
    /// The anchor used for this display: nil means lower-center of the screen, non-nil means a cursor point (AppKit global coordinates).
    private var anchorCursor: CGPoint?

    public init() {}

    // MARK: - Public API

    /// Shows the HUD and sets the initial state.
    /// - Parameters:
    ///   - state: the initial state; `.idle` is equivalent to `hide()` (does not display).
    ///   - cursorPoint: an optional cursor point (AppKit global coordinates, bottom-left origin). When non-nil the HUD floats above it,
    ///     otherwise it is positioned at the lower-center of the screen.
    public func show(state: RecordingState, near cursorPoint: CGPoint? = nil) {
        guard state.isVisible else { hide(); return }
        anchorCursor = cursorPoint
        model.state = state
        if panel == nil {
            buildPanel()
        }
        relayout()
        panel?.orderFrontRegardless()
    }

    /// Updates the HUD state (when the panel is not shown it automatically pops up with the lower-center anchor; `.idle` hides it).
    public func update(state: RecordingState) {
        guard state.isVisible else { hide(); return }
        model.state = state
        if panel == nil {
            show(state: state)
        } else {
            // A state change may change the copy width; re-measure the size and keep the anchor positioning.
            relayout()
        }
    }

    /// Updates the normalized input level (0...1), driving the listening-state waveform indicator. Does not trigger repositioning (only refreshes bar heights).
    public func update(level: Double) {
        model.level = min(max(level, 0), 1)
    }

    /// The current normalized input level (0...1). For the orchestration-layer test to assert "each session's level has been forwarded to the HUD".
    public var currentLevel: Double { model.level }

    /// Hides and destroys the panel.
    public func hide() {
        model.state = .idle
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // MARK: - Panel building / layout

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Layout.initialSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.ignoresMouseEvents = true          // The HUD only displays, it does not intercept clicks (the user operates the app below as usual)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: RecordingPanelView(model: model))
        panel = p
    }

    /// Measures the natural size for the current content, sets the panel size and clamps the position.
    private func relayout() {
        guard let panel else { return }

        // Measure the natural size (including the 2*shadowPad outer margin).
        let measure = NSHostingView(rootView: RecordingPanelView(model: model))
        measure.layout()
        let natural = measure.fittingSize
        let size = NSSize(width: max(natural.width, Layout.initialSize.width),
                          height: max(natural.height, Layout.initialSize.height))

        let screen = screenForAnchor() ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? Layout.fallbackVisibleFrame

        let base: CGPoint
        if let cursor = anchorCursor {
            base = HUDPositioning.aboveCursorOrigin(cursor: cursor, size: size, gap: Layout.cursorGap)
        } else {
            base = HUDPositioning.bottomCenterOrigin(size: size, within: vf,
                                                     bottomMargin: Layout.bottomMargin)
        }
        let origin = HUDPositioning.clamped(origin: base, size: size, within: vf)

        panel.setContentSize(size)
        panel.setFrameOrigin(origin)
    }

    /// The screen the anchor is on: when there is a cursor point, take the screen containing that point, otherwise the main screen.
    private func screenForAnchor() -> NSScreen? {
        guard let cursor = anchorCursor else { return NSScreen.main }
        return NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
    }
}
#endif
