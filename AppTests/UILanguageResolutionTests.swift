import XCTest
@testable import SayIt
@testable import SayItCore

/// Regression guard for the i18n bug: settings-pane copy built with `String(localized:)` ignored the
/// chosen UI language and resolved against the system locale, so on a Chinese-system Mac with Display
/// Language = English the Permissions pane and the microphone-test copy stayed Chinese.
///
/// These run against the real app bundle (`Bundle.main` == the `SayIt.app` test host), which carries the
/// catalog-compiled `en.lproj` / `zh-Hans.lproj` tables. They assert ``UILanguageLocalizer`` returns the
/// requested language's value — independent of the process/system locale — which is exactly what was
/// broken before the fix. Headless and silent.
@MainActor
final class UILanguageResolutionTests: XCTestCase {
    /// App-catalog keys resolve to the English value when English is requested, regardless of system locale.
    func testAppCatalogResolvesEnglish() {
        XCTAssertEqual(resolve("perm.microphone", "Microphone", .english), "Microphone")
        XCTAssertEqual(resolve("perm.status.granted", "Granted", .english), "Granted")
        XCTAssertEqual(resolve("general.testMic", "Test Microphone", .english), "Test Microphone")
        XCTAssertEqual(resolve("general.micHint.idle",
                               "Tap “Test Microphone” to check the selected device has input.", .english),
                       "Tap “Test Microphone” to check the selected device has input.")
    }

    /// The same keys resolve to the Simplified Chinese value when Chinese is requested.
    func testAppCatalogResolvesSimplifiedChinese() {
        XCTAssertEqual(resolve("perm.microphone", "Microphone", .simplifiedChinese), "麦克风")
        XCTAssertEqual(resolve("perm.status.granted", "Granted", .simplifiedChinese), "已授权")
        XCTAssertEqual(resolve("general.testMic", "Test Microphone", .simplifiedChinese), "测试麦克风")
    }

    /// English and Chinese genuinely diverge for the same key — the heart of the bug. If the resolver
    /// silently fell back to the system locale, both would collapse to one language and this fails.
    func testEnglishAndChineseDiverge() {
        for (key, def) in [("perm.microphone", "Microphone"),
                           ("perm.accessibility", "Accessibility"),
                           ("perm.status.granted", "Granted"),
                           ("general.testMic", "Test Microphone"),
                           ("general.stopTest", "Stop Test")] {
            let en = resolve(key, def, .english)
            let zh = resolve(key, def, .simplifiedChinese)
            XCTAssertNotEqual(en, zh, "key \(key) must differ between en and zh-Hans")
            XCTAssertNotEqual(en, key, "key \(key) must not resolve to the bare key (en)")
            XCTAssertNotEqual(zh, key, "key \(key) must not resolve to the bare key (zh)")
        }
    }

    /// The "System Default (%@)" wrapper follows the UI language while the interpolated device name is
    /// inserted verbatim. Verifies both the English and Chinese wrapper resolve and substitute.
    func testSystemDefaultNamedFormatFollowsLanguage() {
        let key = "general.systemDefault.named %@"
        let enFormat = resolve(key, "System Default (%@)", .english)
        let zhFormat = resolve(key, "System Default (%@)", .simplifiedChinese)
        XCTAssertEqual(String(format: enFormat, "MacBook Mic"), "System Default (MacBook Mic)")
        XCTAssertEqual(String(format: zhFormat, "MacBook Mic"), "系统默认（MacBook Mic）")
        XCTAssertNotEqual(enFormat, zhFormat)
    }

    private func resolve(_ key: String, _ def: String, _ language: UILanguage) -> String {
        UILanguageLocalizer.string(key, defaultValue: def, bundle: .main, language: language)
    }
}
