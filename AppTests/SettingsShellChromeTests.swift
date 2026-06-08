import XCTest

/// Regression guards for the Settings shell "window chrome + sidebar shade" follow-ups.
///
/// Two earlier defects this pins down (PR #66 over-/under-shot both):
///
///   1. TITLE BAR STILL SHOWED. #66 added a `WindowConfigurator` AppKit hook to hide the Settings
///      window's title bar, but it (a) ran the config synchronously in `updateNSView`, where the
///      view's window is typically still `nil`, so the config never landed reliably; and (b) omitted
///      `titlebarSeparatorStyle = .none`, leaving the 1pt hairline separator under the title-bar area
///      that made the bar read as still present. The fix defers via `DispatchQueue.main.async` and
///      sets all five chrome properties.
///
///   2. SIDEBAR TOO DARK. #66 set `Theme.sidebarBackground` to `underPageBackgroundColor`, which reads
///      as a medium-dark gray slab in light mode. The fix replaces it with a subtle LIGHT panel (the
///      window background nudged a small fraction toward gray).
///
/// SwiftUI view *structure* and resolved `Color` values are not introspectable at runtime without extra
/// tooling, so — matching `DictionarySettingsViewToolbarTests` — these guards assert at the SOURCE level
/// that the implementation keeps the load-bearing properties. If anyone drops the deferral, a chrome
/// property, the separator removal, or reverts the sidebar to the dark color, the build fails first.
final class SettingsShellChromeTests: XCTestCase {

    /// The `App/SettingsView.swift` source, located relative to this test file inside the repo tree.
    private func settingsViewSource(file: StaticString = #filePath) throws -> String {
        // This test lives at <repo>/AppTests/SettingsShellChromeTests.swift.
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let viewURL = repoRoot.appendingPathComponent("App").appendingPathComponent("SettingsView.swift")
        return try String(contentsOf: viewURL, encoding: .utf8)
    }

    /// The `App/Theme.swift` source, located relative to this test file inside the repo tree.
    private func themeSource(file: StaticString = #filePath) throws -> String {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let themeURL = repoRoot.appendingPathComponent("App").appendingPathComponent("Theme.swift")
        return try String(contentsOf: themeURL, encoding: .utf8)
    }

    /// Source with `//` line comments removed, so guards match on actual CODE rather than explanatory
    /// prose that may legitimately *name* an anti-pattern (e.g. `underPageBackgroundColor`) while
    /// describing why it was dropped. (The settings sources use no `//` inside string literals.)
    private func strippingLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[line.startIndex..<range.lowerBound]
            }
            .joined(separator: "\n")
    }

    // MARK: - Title bar must actually be hidden

    /// The window-chrome hook must apply all five properties that make the title bar disappear — in
    /// particular `titlebarSeparatorStyle = .none`, the hairline-separator removal that #66 missed.
    func testWindowConfiguratorAppliesAllChromeProperties() throws {
        let code = strippingLineComments(try settingsViewSource())
        for required in [
            "titleVisibility = .hidden",
            "titlebarAppearsTransparent = true",
            ".fullSizeContentView",
            "titlebarSeparatorStyle = .none",
            #"title = """#,
        ] {
            XCTAssertTrue(
                code.contains(required),
                """
                WindowConfigurator must set `\(required)` so the Settings window's title bar (and its \
                under-title hairline separator) actually disappears. Missing this reproduces PR #66's \
                still-visible title bar.
                """
            )
        }
    }

    /// The chrome config must be deferred to the next main-loop turn: applied synchronously in
    /// `updateNSView` (as #66 did), `nsView.window` is typically still nil and the config never lands.
    func testWindowConfiguratorDefersUntilWindowAttaches() throws {
        let code = strippingLineComments(try settingsViewSource())
        XCTAssertTrue(
            code.contains("DispatchQueue.main.async"),
            """
            WindowConfigurator must defer its window config via `DispatchQueue.main.async` so it runs \
            after the view is attached to its window; otherwise `nsView.window` is nil and the title \
            bar is never hidden (PR #66's failure mode).
            """
        )
        XCTAssertTrue(
            code.contains("nsView.window"),
            "WindowConfigurator must read the resolved `nsView.window` inside the deferred block."
        )
    }

    // MARK: - Sidebar must be light, not dark

    /// The sidebar must NOT use `underPageBackgroundColor`, which renders as a medium-dark gray slab in
    /// light mode (the #66 over-darkening). It must instead be a subtle light panel.
    func testSidebarBackgroundIsNotTheDarkUnderPageColor() throws {
        let code = strippingLineComments(try themeSource())
        XCTAssertFalse(
            code.contains("underPageBackgroundColor"),
            """
            Theme.sidebarBackground must not use `underPageBackgroundColor`: in light mode it reads as a \
            medium-dark gray slab. Use a subtle LIGHT panel (a hair darker than the content), e.g. the \
            window background blended a small fraction toward gray.
            """
        )
    }

    /// The sidebar background must be derived from the (light) window background, keeping it a light
    /// panel that is only a hair darker than the content — the Typeless-style gentle light-gray sidebar.
    func testSidebarBackgroundIsDerivedFromWindowBackground() throws {
        let code = strippingLineComments(try themeSource())
        XCTAssertTrue(
            code.contains("sidebarBackground"),
            "Theme must still define a `sidebarBackground` token for the settings sidebar."
        )
        XCTAssertTrue(
            code.contains("windowBackgroundColor"),
            """
            Theme.sidebarBackground must be derived from the light `windowBackgroundColor` (nudged a \
            small fraction toward gray) so the sidebar stays a light panel, not a dark one.
            """
        )
    }
}
