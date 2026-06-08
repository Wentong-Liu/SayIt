import XCTest

/// Regression guard for the "stray `+` in the Settings tab bar" bug.
///
/// In a macOS Settings `TabView`, each pane's window-level `.toolbar` items render in the tab-bar row (the tab bar
/// *is* the window toolbar). `DictionarySettingsView` previously declared a window `.toolbar { Button("plus") }` to
/// add an entry, which leaked a stray "+" after the last tab (通用 / 语音识别 / 润色 / 词典 / 权限 / +).
///
/// SwiftUI view *structure* is not introspectable at runtime without extra tooling, so this guard asserts at the
/// source level that `DictionarySettingsView` does NOT use a window-level `.toolbar` modifier, while still exposing
/// an in-content add affordance (the `dictionary.add` action + a `plus` icon inside the pane body). If anyone
/// reintroduces a `.toolbar` add button in this pane, this test fails before the regression ships.
final class DictionarySettingsViewToolbarTests: XCTestCase {

    /// The `DictionarySettingsView.swift` source, located relative to this test file inside the repo tree.
    private func dictionarySettingsViewSource(file: StaticString = #filePath) throws -> String {
        // This test lives at <repo>/AppTests/DictionarySettingsViewToolbarTests.swift.
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let viewURL = repoRoot
            .appendingPathComponent("App")
            .appendingPathComponent("Settings")
            .appendingPathComponent("DictionarySettingsView.swift")
        return try String(contentsOf: viewURL, encoding: .utf8)
    }

    /// The source with `//` line comments removed, so guards match on actual code rather than explanatory prose that
    /// may mention an anti-pattern by name. (A simple stripper: this file's source uses no `//` inside string literals.)
    private func dictionarySettingsViewSourceWithoutLineComments(file: StaticString = #filePath) throws -> String {
        try dictionarySettingsViewSource(file: file)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[line.startIndex..<range.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The pane must NOT use a window-level `.toolbar` modifier: in a Settings `TabView` that surfaces as a stray "+"
    /// (or other items) in the tab-bar row. Line comments (which may legitimately *mention* `.toolbar` to explain the
    /// anti-pattern) are stripped before checking, so only an actual `.toolbar` modifier in code trips this guard.
    func testDictionaryPaneHasNoWindowToolbar() throws {
        let code = try dictionarySettingsViewSourceWithoutLineComments()
        XCTAssertFalse(
            code.contains(".toolbar"),
            """
            DictionarySettingsView must not declare a window-level `.toolbar`: in a macOS Settings `TabView` the \
            window toolbar IS the tab bar, so a toolbar item (e.g. an add `+` button) leaks into the tab row as a \
            stray control. Keep the add affordance inside the pane content (section header / empty-state button).
            """
        )
    }

    /// The add affordance must still exist somewhere in the pane body so users can add an entry.
    func testDictionaryPaneStillHasInContentAddAffordance() throws {
        let source = try dictionarySettingsViewSource()
        XCTAssertTrue(
            source.contains("editorContext = .add"),
            "DictionarySettingsView must keep an in-content add action that presents the new-entry editor."
        )
        XCTAssertTrue(
            source.contains("dictionary.add"),
            "DictionarySettingsView must keep the `dictionary.add` label for its in-content add affordance."
        )
    }
}
