#if canImport(AppKit)
import AppKit
import SwiftUI

/// A small, dismissible, **clickable** floating panel that asks the user whether to add a learned word to the dictionary
/// ("Add \"{corrected}\" to dictionary?" with Add / Dismiss).
///
/// This is the suggestion affordance of the learn-from-edits feature (Part B). It is deliberately a SEPARATE controller
/// from ``RecordingPanelController``:
/// - The dictation HUD panel sets `ignoresMouseEvents = true` and so CANNOT host clickable buttons; this panel must
///   accept clicks for Add / Dismiss.
/// - It is a `.nonactivatingPanel` + `.floating` so it does NOT steal focus from the user's app (the user keeps typing /
///   editing in the foreground app while the suggestion floats), yet its buttons remain clickable.
/// - It auto-dismisses after a few seconds via an internal task, treating an auto-dismiss exactly like an explicit Dismiss
///   (the `onDismiss` closure runs once), so the coordinator always clears its pending injection record.
///
/// It owns no dictation state: the coordinator drives it with ``show(corrected:heard:onAccept:onDismiss:)`` and reacts to
/// the two closures. ``RecordingState`` and ``RecordingPanelView``'s exhaustive switch are intentionally left untouched
/// (the codebase avoids adding enum cases that disturb that switch).
@MainActor
public final class SuggestionPanelController {
    /// Process-level shared instance (the suggestion prompt is globally unique, like the HUD).
    public static let shared = SuggestionPanelController()

    /// Panel layout constants.
    private enum Layout {
        /// The spacing of the panel's bottom edge from the bottom of the visible region (sits a little above the dictation HUD anchor).
        static let bottomMargin: CGFloat = 150
        /// The initial size when creating a new panel (relaid out by content right after creation).
        static let initialSize = NSSize(width: 280, height: 64)
        /// Fallback rect when the screen's visibleFrame cannot be obtained.
        static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// How long the suggestion stays up before auto-dismissing (treated as an implicit Dismiss). Injectable for tests.
    private let autoDismissAfter: Duration

    /// When true, the controller wires up the model + closures + auto-dismiss task as usual but never builds, orders, or
    /// destroys an AppKit panel. Used ONLY by headless tests so the suite is windowless; production always uses the
    /// default `false`, so ``shared`` and every default `init(autoDismissAfter:)` caller keep their exact AppKit behavior.
    private let headless: Bool

    private var panel: NSPanel?
    private let model = SuggestionPanelModel()
    /// The in-flight auto-dismiss task; cancelled+replaced on each ``show(...)`` and on ``hide()``.
    private var autoDismissTask: Task<Void, Never>?
    /// Tracks "is a suggestion currently shown" independently of `panel` so ``_test_isShown`` stays correct in headless
    /// tests (where `panel` is always nil). In production `panel != nil` and this flag agree.
    private var shownForTest = false

    /// - Parameters:
    ///   - autoDismissAfter: how long the suggestion stays visible before auto-dismissing; defaults to 6s. Tests pass a tiny value.
    ///   - headless: when true, suppresses all NSPanel creation/ordering (test-only); defaults to false so production is byte-identical.
    public init(autoDismissAfter: Duration = .seconds(6), headless: Bool = false) {
        self.autoDismissAfter = autoDismissAfter
        self.headless = headless
    }

    // MARK: - Public API

    /// Shows the suggestion prompt for `corrected` (the word the user typed in place of the misheard `heard`).
    ///
    /// Replaces any prior suggestion. `onAccept` fires once if the user clicks Add; `onDismiss` fires once on an explicit
    /// Dismiss click OR on auto-dismiss. Exactly one of the two closures runs per shown suggestion, then the panel hides.
    /// - Parameters:
    ///   - corrected: the corrected word to offer adding (shown in the prompt, becomes the entry's canonical form).
    ///   - heard: the originally-injected (misheard) word (becomes the entry's variant). Carried for the caller; not shown.
    ///   - onAccept: invoked on the main thread when the user accepts (clicks Add).
    ///   - onDismiss: invoked on the main thread when the user dismisses OR the auto-dismiss fires.
    public func show(corrected: String,
                     heard: String,
                     onAccept: @escaping () -> Void,
                     onDismiss: @escaping () -> Void) {
        // Cancel any prior auto-dismiss so a stale sleeper can never dismiss this fresh suggestion.
        autoDismissTask?.cancel()

        // A one-shot guard so neither closure can run twice (e.g. a click landing right as auto-dismiss fires).
        var didResolve = false
        let accept: () -> Void = { [weak self] in
            guard let self, !didResolve else { return }
            didResolve = true
            self.hide()
            onAccept()
        }
        let dismiss: () -> Void = { [weak self] in
            guard let self, !didResolve else { return }
            didResolve = true
            self.hide()
            onDismiss()
        }

        model.corrected = corrected
        model.onAccept = accept
        model.onDismiss = dismiss
        shownForTest = true

        if !headless {   // headless tests: keep model + closures wired, skip the clickable window
            if panel == nil {
                buildPanel()
            }
            relayout()
            panel?.orderFrontRegardless()
        }

        // Auto-dismiss after the window: treated exactly like an explicit Dismiss (clears the caller's record).
        autoDismissTask = Task { [weak self, autoDismissAfter] in
            try? await Task.sleep(for: autoDismissAfter)
            if Task.isCancelled { return }
            guard self != nil else { return }
            dismiss()
        }
    }

    /// Hides and destroys the panel and cancels the pending auto-dismiss. Idempotent.
    public func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        shownForTest = false
        guard !headless else { return }   // headless tests: panel is always nil here anyway; skip AppKit
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // MARK: - Test seams

    /// Whether the suggestion panel is currently shown. For tests/diagnostics.
    /// Uses `shownForTest` so it is correct in headless tests (where `panel` is always nil); in production the
    /// `panel != nil` term agrees with the flag.
    public var _test_isShown: Bool { panel != nil || shownForTest }

    /// Directly invokes the current suggestion's Accept action (as if the user clicked Add), since the SwiftUI buttons
    /// cannot be clicked in a headless unit test. No-op when nothing is shown.
    public func _test_accept() { model.onAccept?() }

    /// Directly invokes the current suggestion's Dismiss action (as if the user clicked Dismiss). No-op when nothing is shown.
    public func _test_dismiss() { model.onDismiss?() }

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
        // Unlike the dictation HUD, this panel MUST accept clicks (Add / Dismiss), so it does NOT ignore mouse events.
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: SuggestionPanelView(model: model))
        panel = p
    }

    /// Measures the natural size for the current content, sets the panel size and positions it at the lower-center of the screen.
    private func relayout() {
        guard let panel else { return }

        let measure = NSHostingView(rootView: SuggestionPanelView(model: model))
        measure.layout()
        let natural = measure.fittingSize
        let size = NSSize(width: max(natural.width, Layout.initialSize.width),
                          height: max(natural.height, Layout.initialSize.height))

        let screen = NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? Layout.fallbackVisibleFrame

        let base = HUDPositioning.bottomCenterOrigin(size: size, within: vf,
                                                     bottomMargin: Layout.bottomMargin)
        let origin = HUDPositioning.clamped(origin: base, size: size, within: vf)

        panel.setContentSize(size)
        panel.setFrameOrigin(origin)
    }
}

/// The suggestion panel's view model: the controller writes the corrected word + action closures, the view observes.
@MainActor
final class SuggestionPanelModel: ObservableObject {
    /// The corrected word offered for adding (shown in the prompt).
    @Published var corrected: String = ""
    /// The Add action (set by the controller; wired to the Add button).
    var onAccept: (() -> Void)?
    /// The Dismiss action (set by the controller; wired to the Dismiss button).
    var onDismiss: (() -> Void)?
}

/// The suggestion prompt's SwiftUI content: "Add \"{corrected}\" to dictionary?" with Add / Dismiss buttons.
struct SuggestionPanelView: View {
    /// Transparent outer margin around the card: leaves rendering space for the shadow (mirrors ``RecordingPanelView``).
    static let shadowPad: CGFloat = 16
    private static let cornerRadius: CGFloat = 16

    @ObservedObject var model: SuggestionPanelModel

    var body: some View {
        HStack(spacing: 12) {
            Text(titleText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 180, alignment: .leading)

            Button(action: { model.onDismiss?() }) {
                Text(Self.localized("learn.suggestion.dismiss", fallback: "Dismiss"))
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))

            Button(action: { model.onAccept?() }) {
                Text(Self.localized("learn.suggestion.accept", fallback: "Add"))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.9))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                )
        )
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .padding(Self.shadowPad)
    }

    /// The localized prompt "Add \"{corrected}\" to dictionary?" with the corrected word substituted.
    private var titleText: String {
        let format = Self.localized("learn.suggestion.title", fallback: "Add \"%@\" to dictionary?")
        return String(format: format, model.corrected)
    }

    /// Gets localized copy from the in-bundle `Localizable.xcstrings`; falls back to English when the key is missing.
    private static func localized(_ key: String, fallback: String) -> String {
        let value = String(localized: String.LocalizationValue(key),
                           bundle: .module,
                           comment: "Learn-from-edits suggestion prompt")
        return value == key ? fallback : value
    }
}
#endif
