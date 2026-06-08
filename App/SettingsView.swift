import SwiftUI
import SayItCore

/// The SayIt settings main interface: a custom left-sidebar window (Typeless-style) carrying the
/// sections "General / Speech Recognition / Polish / Dictionary / Permissions".
///
/// It only does the settings UI and reading/writing config/credentials, binding the existing ``AppConfig`` and ``KeychainStore`` (via ``SettingsViewModel``),
/// without end-to-end dictation orchestration (which belongs to T13). All config enums reuse `SayItCore`'s single source of truth, not redeclared.
///
/// Phase 1 of the redesign replaces the plain native `TabView` with a branded two-column layout
/// (sidebar + content). The four non-dictionary panes are hosted unchanged in the new content
/// area — only the shell and the Dictionary pane are restyled this round.
struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    /// A single shared user-dictionary store for the Dictionary pane. A default ``DictionaryStore`` points at the
    /// same `dictionary.json` the dictation pipeline reads, so entries added here immediately feed PR-2's rewriter.
    @State private var dictionaryStore = DictionaryStore()

    /// The currently selected sidebar section. Defaults to General, matching the prior `TabView` first tab.
    @State private var selection: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(width: 720, height: 520)
        .tint(Theme.accent)
        // Hide the settings window's title bar so the custom sidebar + content fill the whole
        // window and the traffic-light buttons float over the sidebar's top-left (Typeless-style).
        .background(WindowConfigurator())
        // Consume-once: if something (the first-run guidance) requested a specific opening tab, land
        // there instead of the default General, then clear the request so later opens are unaffected.
        .onAppear {
            if let tab = SettingsRouter.shared.pendingTab {
                selection = tab
                SettingsRouter.shared.pendingTab = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Branded header: the monochrome speech-mark glyph tinted to the accent + the "SayIt" wordmark.
            HStack(spacing: 8) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Theme.accent)
                Text(verbatim: "SayIt")
                    .font(Theme.Typography.paneTitle)
            }
            // Extra top inset (~28pt over the base 16) so the floating traffic-light buttons,
            // now overlaying the title-bar-less window, clear the "SayIt" brand header.
            .padding(.top, 44)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            // Navigation items.
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarRow(tab: tab, isSelected: selection == tab) {
                        selection = tab
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            // Subtle footer: app name + version only. No upgrade/paywall — SayIt is free.
            Text(verbatim: "SayIt \(Self.appVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBackground)
    }

    /// The short marketing version (CFBundleShortVersionString), shown verbatim in the sidebar footer.
    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? ""
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsView(viewModel: viewModel)
            case .stt:
                STTSettingsView(viewModel: viewModel)
            case .polish:
                PolishSettingsView(viewModel: viewModel)
            case .dictionary:
                DictionarySettingsView(store: dictionaryStore, viewModel: viewModel)
            case .permissions:
                PermissionsSettingsView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }
}

// MARK: - Tabs

/// The five settings sections, carrying the localized label key + SF Symbol that the prior `TabView`
/// `.tabItem` pairs used (reused verbatim so the sidebar reads identically to the old tab bar).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, stt, polish, dictionary, permissions

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .general: return "tab.general"
        case .stt: return "tab.stt"
        case .polish: return "tab.polish"
        case .dictionary: return "tab.dictionary"
        case .permissions: return "tab.permissions"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .stt: return "waveform"
        case .polish: return "sparkles"
        case .dictionary: return "character.book.closed"
        case .permissions: return "lock.shield"
        }
    }
}

// MARK: - Sidebar row

/// A single sidebar navigation item. Selected = a filled rounded-rect highlight in the accent color
/// with white foreground (Typeless-style); unselected = plain with a subtle hover fill.
private struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(tab.labelKey, systemImage: tab.systemImage)
                .font(Theme.Typography.label)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(background)
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected { return Theme.accent }
        if isHovering { return Theme.hoverFill }
        return .clear
    }
}

// MARK: - Window chrome

/// An invisible AppKit hook that strips the title bar from the hosting `Settings` window.
///
/// The `Settings` scene is not a `WindowGroup`/`Window`, so SwiftUI's `.windowStyle(.hiddenTitleBar)`
/// does not apply to it. Placed in the settings view's background, this grabs `view.window` once it
/// resolves and makes the chrome disappear, leaving the custom sidebar + content to fill the window
/// with the traffic lights floating over the sidebar's top-left (Typeless-style).
///
/// Why a deferred `DispatchQueue.main.async`: in `makeNSView` (and often the first `updateNSView`
/// pass) `view.window` is still `nil` because the representable's view has not yet been attached to a
/// window. PR #66 applied the config synchronously in `updateNSView`, so on the pass where the window
/// finally existed the early-return guard had already (in the same run loop) raced the layout — the
/// result was a still-visible title bar. We instead hop to the next main-loop turn, by which point the
/// view is reliably hosted, and configure the resolved window then.
///
/// Why `titlebarSeparatorStyle = .none`: even with a hidden, transparent, full-size-content title bar,
/// macOS draws a 1pt hairline separator under the title-bar area by default. That hairline was the
/// visible remnant in #66 that made the bar still read as present; `.none` removes it.
///
/// Idempotent: every step is a set-to-a-fixed-value (or an insert into an `OptionSet`), so re-running
/// it on later layout passes is a no-op and never thrashes the chrome.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Defer to the next main-loop turn: the view is reliably attached to its window by then,
        // whereas `nsView.window` is typically still nil during make/first-update.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarSeparatorStyle = .none
            window.title = ""
        }
    }
}

#Preview {
    SettingsView()
}
