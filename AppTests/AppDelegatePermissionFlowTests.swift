import XCTest

/// Regression guards for first-run permission onboarding.
///
/// The first launch opens Settings while macOS is showing the microphone authorization dialog. When that dialog
/// closes, an accessory app is not reliably reactivated, so the Settings window can sit behind other apps. The same
/// startup flow should also ask for Accessibility immediately after the microphone request, instead of waiting until
/// the user first presses the dictation hotkey.
final class AppDelegatePermissionFlowTests: XCTestCase {
    private func appDelegateSource(file: StaticString = #filePath) throws -> String {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("App").appendingPathComponent("AppDelegate.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func strippingLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[line.startIndex..<range.lowerBound]
            }
            .joined(separator: "\n")
    }

    func testStartupPermissionFlowRequestsAccessibilityAfterMicrophone() throws {
        let code = strippingLineComments(try appDelegateSource())

        XCTAssertTrue(
            code.contains("AccessibilityAuthorization.ensureTrusted(prompting: true)"),
            "After the microphone request completes, startup onboarding should trigger the Accessibility prompt too."
        )
    }

    func testStartupPermissionFlowReactivatesSettingsAfterMicrophonePrompt() throws {
        let code = strippingLineComments(try appDelegateSource())

        XCTAssertTrue(
            code.contains("NSApp.activate(ignoringOtherApps: true)"),
            "When the microphone dialog closes, the accessory app must reactivate so Settings does not stay behind other apps."
        )
        XCTAssertTrue(
            code.contains("orderFrontRegardless()") || code.contains("makeKeyAndOrderFront"),
            "Reactivation should also bring visible app windows, including Settings, back to the front."
        )
    }
}
