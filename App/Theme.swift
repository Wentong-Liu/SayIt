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

    /// The sidebar's background: a darker neutral surface a clear step below the content pane,
    /// so the column reads as separate without a divider (light/dark adaptive — `underPageBackgroundColor`
    /// is reliably a notch darker than `windowBackgroundColor` in light mode and adapts in dark).
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)

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
