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

    /// The transient HUD copy that ``DictationCoordinator`` builds imperatively (transcription failed,
    /// microphone/accessibility required, "didn't catch that", paste-manually hints, …) must follow the
    /// chosen UI language too. These feed straight into `RecordingState.error/.info`, whose `displayText`
    /// returns the message verbatim, bypassing the in-bundle resolver — so before the fix they stayed in
    /// the system locale. This guards that whole HUD category, not just the fixed-state pill. If any key
    /// reverted to a raw `String(localized:)`, en and zh-Hans would collapse and this fails.
    func testCoordinatorHUDCopyFollowsLanguage() {
        let keys: [(String, String)] = [
            ("hud.needAccessibility", "Accessibility permission required — enable it in System Settings"),
            ("hud.stopRecordingFailed", "Failed to finish recording"),
            ("hud.transcriptionFailed", "Transcription failed"),
            ("hud.pastedToCurrentWindow", "Pasted to the current window"),
            ("hud.injectedPolishFailed", "Inserted (polish failed, used original text)"),
            ("hud.driftedCopiedPasteManually", "Focus changed — text copied, please paste manually"),
            ("hud.copiedPasteManually", "Copied to clipboard, please paste manually"),
            ("hud.didNotCatchThat", "Didn’t catch that, please try again"),
            ("hud.needMicrophone", "Microphone permission required"),
            ("hud.cannotStartRecording", "Cannot start recording"),
            ("hud.transcriberNotReady", "Transcription not ready — check model/API key"),
            ("hud.unsupportedAudioFormat", "Unsupported audio format"),
        ]
        for (key, def) in keys {
            let en = resolve(key, def, .english)
            let zh = resolve(key, def, .simplifiedChinese)
            XCTAssertNotEqual(en, zh, "HUD key \(key) must differ between en and zh-Hans")
            XCTAssertNotEqual(en, key, "HUD key \(key) must not resolve to the bare key (en)")
            XCTAssertNotEqual(zh, key, "HUD key \(key) must not resolve to the bare key (zh)")
            XCTAssertEqual(en, def, "HUD key \(key) English value must match the source defaultValue")
        }
    }

    /// The local-model picker labels (`SettingsViewModel.localModelOptions`) are built imperatively with
    /// the resolver, so they must follow the chosen UI language. Before this fix they used a raw
    /// `String(localized:)` and resolved against the system locale — so on a Chinese-system Mac in English
    /// UI mode the dropdown showed "large-v3-turbo（推荐）", "large-v3（最高精度）", … . This asserts the
    /// English value in English mode and the Chinese value in Chinese mode, per model key.
    func testLocalModelLabelsFollowLanguage() {
        let cases: [(key: String, en: String, zh: String)] = [
            ("model.large-v3-turbo", "large-v3-turbo (recommended)", "large-v3-turbo（推荐）"),
            ("model.large-v3", "large-v3 (highest accuracy)", "large-v3（最高精度）"),
            ("model.medium", "medium (balanced)", "medium（均衡）"),
            ("model.small", "small (lightweight)", "small（轻量）"),
            ("model.base", "base (fastest)", "base（最快）"),
        ]
        for c in cases {
            XCTAssertEqual(resolve(c.key, c.en, .english), c.en, "\(c.key) must be English in English mode")
            XCTAssertEqual(resolve(c.key, c.en, .simplifiedChinese), c.zh, "\(c.key) must be Chinese in Chinese mode")
            XCTAssertNotEqual(resolve(c.key, c.en, .english), resolve(c.key, c.en, .simplifiedChinese),
                              "\(c.key) en and zh-Hans must diverge")
        }
    }

    /// End-to-end guard through the live `SettingsViewModel.localModelOptions` computed property — the exact
    /// call site the bug names — not just the resolver. `localModelOptions` resolves through the convenience
    /// `uiLanguageLocalized`, which reads the persisted UI language from `UserDefaults.standard`; so this
    /// drives that key directly (saving/restoring it) and asserts the built picker labels switch language.
    func testLocalModelOptionsResolveInSelectedLanguage() {
        let key = "ui.language"
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let vm = SettingsViewModel(config: AppConfig())

        UserDefaults.standard.set(UILanguage.english.rawValue, forKey: key)
        let enLabels = vm.localModelOptions.map(\.label)
        XCTAssertEqual(enLabels.first, "large-v3-turbo (recommended)")
        XCTAssertTrue(enLabels.contains("base (fastest)"))
        for label in enLabels {
            XCTAssertFalse(label.contains("推荐") || label.contains("精度") || label.contains("均衡")
                           || label.contains("轻量") || label.contains("最快"),
                           "English-mode picker label leaked Chinese: \(label)")
        }

        UserDefaults.standard.set(UILanguage.simplifiedChinese.rawValue, forKey: key)
        let zhLabels = vm.localModelOptions.map(\.label)
        XCTAssertEqual(zhLabels.first, "large-v3-turbo（推荐）")
        XCTAssertTrue(zhLabels.contains("base（最快）"))
    }

    /// The settings status/login copy swept alongside the model labels (key-save status, ChatGPT login
    /// status, the OAuth error descriptions surfaced as the polish-pane status, the browser "done" page)
    /// must also follow the UI language. Each carries a real en/zh-Hans pair in the catalog, so before the
    /// fix they leaked the system locale.
    func testSweptSettingsCopyFollowsLanguage() {
        let keys: [(String, String)] = [
            ("polish.openingBrowser", "Opening browser to authorize ChatGPT…"),
            ("polish.loginSucceeded", "ChatGPT login succeeded"),
            ("polish.loggedOut", "Signed out of ChatGPT"),
            ("polish.logoutFailed", "Sign-out failed"),
            ("polish.keySaved %@", "%@ key saved"),
            ("polish.keySaveFailed %@", "Failed to save %@ key"),
            ("polish.apiKeyField %@", "%@ API Key"),
            ("login.stateMismatch", "State verification failed"),
            ("login.noCode", "No authorization code in callback"),
            ("login.cancelled", "Login cancelled"),
            ("login.timedOut", "Login timed out, please try again"),
            ("login.serverFailed %lld", "Local loopback server failed to start (port %lld may be in use)"),
            ("login.exchangeFailed %@", "Token exchange failed: %@"),
            ("login.keychainWriteFailed", "Unable to write to keychain"),
            ("login.browserDone", "SayIt: Login complete. You can close this page and return to the app."),
            ("polish.loginFailed %@", "ChatGPT login failed: %@"),
        ]
        for (key, def) in keys {
            let en = resolve(key, def, .english)
            let zh = resolve(key, def, .simplifiedChinese)
            XCTAssertEqual(en, def, "key \(key) English value must match the source defaultValue")
            // polish.apiKeyField is identical across languages by design (it is "%@ API Key" in both),
            // so it is exempt from the divergence check; every other swept key genuinely differs.
            if key != "polish.apiKeyField %@" {
                XCTAssertNotEqual(en, zh, "key \(key) must differ between en and zh-Hans")
            }
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
