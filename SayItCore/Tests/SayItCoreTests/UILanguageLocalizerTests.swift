import XCTest
@testable import SayItCore

/// Tests for ``UILanguageLocalizer`` — the resolver that makes imperatively-built copy follow the
/// chosen UI language instead of the system locale (the i18n bug fix).
///
/// The raw `.xcstrings` is not compiled into per-language `.lproj` tables under SwiftPM (it ships
/// verbatim), so this builds a real `.lproj` fixture bundle in a temp directory — `en.lproj` +
/// `zh-Hans.lproj`, each with `Localizable.strings` defining `test.greeting`. The resolver then reads
/// from it exactly as it reads the app's catalog-compiled bundle at runtime, letting us verify the
/// resolved-value branch (not just the fallback).
final class UILanguageLocalizerTests: XCTestCase {
    private var fixtureRoot: URL!
    private var fixtureBundle: Bundle!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A throwaway bundle directory containing en.lproj + zh-Hans.lproj with one localized key each.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UILanguageLocalizerTests-\(UUID().uuidString)", isDirectory: true)
        let table: [(code: String, value: String)] = [("en", "Hello"), ("zh-Hans", "你好")]
        for entry in table {
            let lproj = root.appendingPathComponent("\(entry.code).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let strings = "\"test.greeting\" = \"\(entry.value)\";\n"
            try strings.write(to: lproj.appendingPathComponent("Localizable.strings"),
                              atomically: true, encoding: .utf8)
        }
        fixtureRoot = root
        fixtureBundle = try XCTUnwrap(Bundle(url: root), "fixture bundle must load")
    }

    override func tearDownWithError() throws {
        if let root = fixtureRoot { try? FileManager.default.removeItem(at: root) }
        fixtureRoot = nil
        fixtureBundle = nil
        try super.tearDownWithError()
    }

    /// An explicit language returns that language's value for a key present in both en and zh-Hans.
    func testExplicitLanguageReturnsThatLanguageValue() {
        let en = UILanguageLocalizer.string("test.greeting", defaultValue: "FALLBACK",
                                            bundle: fixtureBundle, language: .english)
        XCTAssertEqual(en, "Hello")

        let zh = UILanguageLocalizer.string("test.greeting", defaultValue: "FALLBACK",
                                            bundle: fixtureBundle, language: .simplifiedChinese)
        XCTAssertEqual(zh, "你好")
    }

    /// The two languages resolve to genuinely different values (the whole point of the fix): selecting
    /// English on a Chinese system must NOT yield the Chinese string.
    func testLanguagesDiverge() {
        let en = UILanguageLocalizer.string("test.greeting", defaultValue: "FALLBACK",
                                            bundle: fixtureBundle, language: .english)
        let zh = UILanguageLocalizer.string("test.greeting", defaultValue: "FALLBACK",
                                            bundle: fixtureBundle, language: .simplifiedChinese)
        XCTAssertNotEqual(en, zh)
        XCTAssertEqual(en, "Hello")
        XCTAssertEqual(zh, "你好")
    }

    /// A key absent from the language's table falls back to `defaultValue` — never the bare key, never blank.
    func testMissingKeyFallsBackToDefaultValueNotBareKey() {
        let resolved = UILanguageLocalizer.string("test.does.not.exist", defaultValue: "Safe Default",
                                                  bundle: fixtureBundle, language: .english)
        XCTAssertEqual(resolved, "Safe Default")
        XCTAssertNotEqual(resolved, "test.does.not.exist")
        XCTAssertFalse(resolved.isEmpty)
    }

    /// A bundle with no resolvable `.lproj` for the key still resolves safely (no crash, no bare key):
    /// it falls through to the normal `String(localized:)` and then to `defaultValue`.
    func testUnresolvableBundleFallsBackSafely() {
        let emptyBundle = Bundle(for: type(of: self))
        let resolved = UILanguageLocalizer.string("test.greeting", defaultValue: "Default Hello",
                                                  bundle: emptyBundle, language: .english)
        XCTAssertEqual(resolved, "Default Hello")
        XCTAssertNotEqual(resolved, "test.greeting")
        XCTAssertFalse(resolved.isEmpty)
    }

    /// The live convenience (default `language:`) reads the persisted setting and resolves through it,
    /// so it never returns the bare key and never crashes even when the bundle has no matching `.lproj`.
    func testLiveConvenienceFallsBackSafely() {
        let resolved = UILanguageLocalizer.string("test.greeting", defaultValue: "Default Hello",
                                                  bundle: Bundle(for: type(of: self)))
        XCTAssertEqual(resolved, "Default Hello")
        XCTAssertNotEqual(resolved, "test.greeting")
    }

    /// The lproj name maps exactly to the persisted BCP-47 identifier / compiled `.lproj` directory name.
    func testLprojNameMapping() {
        XCTAssertEqual(UILanguage.english.lprojName, "en")
        XCTAssertEqual(UILanguage.simplifiedChinese.lprojName, "zh-Hans")
    }
}

/// Verifies the nonisolated persisted-language accessor that bridges the `@MainActor` config to the
/// nonisolated HUD path. Uses an isolated `UserDefaults` suite (no pollution of `.standard`).
final class PersistedUILanguageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PersistedUILanguageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testReadsPersistedExplicitValue() {
        defaults.set("en", forKey: "ui.language")
        XCTAssertEqual(AppConfig.persistedUILanguage(defaults), .english)
        defaults.set("zh-Hans", forKey: "ui.language")
        XCTAssertEqual(AppConfig.persistedUILanguage(defaults), .simplifiedChinese)
    }

    func testUnsetFallsBackToSystemDefault() {
        // No value persisted -> the same system-default mapping the instance getter uses.
        XCTAssertEqual(AppConfig.persistedUILanguage(defaults), UILanguage.systemDefault)
    }

    func testGarbledValueFallsBackToSystemDefault() {
        defaults.set("not-a-language", forKey: "ui.language")
        XCTAssertEqual(AppConfig.persistedUILanguage(defaults), UILanguage.systemDefault)
    }

    /// The nonisolated accessor agrees with the `@MainActor` instance getter for the same store.
    @MainActor
    func testMatchesInstanceGetter() {
        let config = AppConfig(defaults: defaults)
        config.uiLanguage = .english
        XCTAssertEqual(AppConfig.persistedUILanguage(defaults), config.uiLanguage)
        config.uiLanguage = .simplifiedChinese
        XCTAssertEqual(AppConfig.persistedUILanguage(defaults), config.uiLanguage)
    }
}
