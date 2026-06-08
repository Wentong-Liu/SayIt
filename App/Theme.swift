import SwiftUI

/// A small, cohesive design system for the SayIt settings window.
///
/// Phase 1 of the Typeless-style sidebar redesign uses these tokens in the settings shell
/// (``SettingsView``) and the restyled Dictionary pane. The accent is an indigo/purple that
/// reads as a "brand" tint on the selected sidebar item and primary buttons; the rest are
/// native, system-driven surfaces so the window stays light/dark adaptive and feels at home
/// on macOS. No color is claimed to be sampled from the app icon (which is a monochrome
/// dark-ink speech mark on a cream field) — the accent is a deliberate, tasteful choice.
enum Theme {
    /// Selection highlight + primary ("add new entry") buttons. Indigo/purple per the design.
    static let accent = Color.indigo

    /// The sidebar's background: a SUBTLE LIGHT panel a hair darker than the content pane, so the
    /// column reads as separate without a divider — but stays light, never a dark slab (Typeless's
    /// gentle light-gray sidebar). It is the standard window background nudged a *small* fraction
    /// toward a neutral gray: in light mode that yields a soft, slightly-off-white panel; in dark mode
    /// the same gentle blend keeps the column a touch distinct, so it stays light/dark adaptive.
    /// (`underPageBackgroundColor` — used previously — reads as a medium-dark gray in light mode, far
    /// too heavy for a sidebar; this faint blend is the deliberately gentle replacement.)
    static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        // Resolve the semantic window background for THIS appearance, then blend just 8% toward gray
        // so the panel reads as "a hair darker than the content", not as a dark panel.
        var base = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            base = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
        }
        return base.blended(withFraction: 0.08, of: .gray) ?? base
    })

    /// The content pane background: the standard window background, a light neutral.
    static let contentBackground = Color(nsColor: .windowBackgroundColor)

    /// Elevated "card" surface for the dictionary entry rows.
    static let cardBackground = Color(nsColor: .controlBackgroundColor)

    /// A subtle stroke around cards so they separate on the content background.
    static let cardStroke = Color(nsColor: .separatorColor).opacity(0.5)

    /// Hover feedback fill for unselected sidebar rows.
    static let hoverFill = accent.opacity(0.12)

    /// Corner radius for sidebar selection highlights and small controls.
    static let cornerRadius: CGFloat = 8

    /// Corner radius for cards.
    static let cardCornerRadius: CGFloat = 10

    // Spacing tokens.
    static let sectionGap: CGFloat = 12
    static let rowPadH: CGFloat = 12
    static let rowPadV: CGFloat = 8
}

// MARK: - Typography

/// Typography tokens for the settings window, kept in the design system so the sidebar and the
/// content panes provably share one scale and bump together.
///
/// After the sidebar nav font was enlarged to 15pt (#72), the right-hand content pane still rendered
/// at the tiny native control defaults (~13pt labels/values, ~11pt `.footnote` captions, and a default
/// grouped-form section header), so it read small and unbalanced next to the big sidebar. These tokens
/// scale the content one notch up to match — primary text lands on the same 15pt as the sidebar — while
/// preserving the hierarchy: brand/pane title (`title3`) > body labels/values (15) > headers/captions (13).
extension Theme {
    enum Typography {
        /// Content base, row labels, and trailing values. Matches the 15pt sidebar nav so the two columns
        /// read at one scale. Applied to a grouped `Form` via `.settingsFormTypography()` so it cascades to
        /// the implicit-font controls (Picker/LabeledContent/Toggle/SecureField/Button) without touching any binding.
        static let label: Font = .system(size: 15)

        /// Grouped-form section headers. They sit a step below body in the grouped chrome, so one notch up
        /// from the tiny default (13pt semibold) keeps the header subordinate to the 15pt body while still
        /// being clearly readable.
        static let sectionHeader: Font = .system(size: 13, weight: .semibold)

        /// Section footers / inline hints. `.subheadline` (~13pt) is up from the old `.footnote` (~11pt) yet
        /// stays visibly secondary to the 15pt body, preserving the caption role.
        static let caption: Font = .subheadline

        /// An in-content pane title (the Dictionary header, the sidebar brand wordmark). Tokenized so the
        /// title scale stays in sync across the shell and panes.
        static let paneTitle: Font = .title3.weight(.semibold)
    }
}

// MARK: - Reusable surfaces & styles

extension View {
    /// Wraps content in an elevated, rounded card surface with a subtle stroke.
    func cardSurface() -> some View {
        self
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }

    /// Sets the base content font for a grouped settings `Form` to ``Theme/Typography/label`` (15pt),
    /// cascading to every control label and trailing value (Picker/LabeledContent/Toggle/SecureField/Button)
    /// without touching any binding or control behavior. Apply once per `Form`, alongside `.formStyle(.grouped)`.
    /// Section headers and footers are drawn by the grouped-form chrome and are NOT covered by this; bump those
    /// explicitly with ``settingsSectionHeader()`` / ``settingsCaption()``.
    func settingsFormTypography() -> some View {
        self.environment(\.font, Theme.Typography.label)
    }

    /// Styles a grouped-form section header `Text` at ``Theme/Typography/sectionHeader`` (13pt semibold) —
    /// one notch up from the tiny native default so headers read clearly against the 15pt body.
    func settingsSectionHeader() -> some View {
        self.font(Theme.Typography.sectionHeader)
    }

    /// Styles a section footer / inline hint at ``Theme/Typography/caption`` (~13pt) in the secondary color —
    /// the DRY replacement for the repeated `.font(.footnote).foregroundStyle(.secondary)` pairs. (For the rare
    /// non-secondary caption — e.g. a red failure reason — apply `.font(Theme.Typography.caption)` directly and
    /// keep that line's own `.foregroundStyle`.)
    func settingsCaption() -> some View {
        self.font(Theme.Typography.caption).foregroundStyle(.secondary)
    }
}

/// A rounded, accent-filled "pill" button used for the primary add affordance (Typeless-style).
struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.accent, in: Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule(style: .continuous))
    }
}
