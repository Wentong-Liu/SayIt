import XCTest
@testable import SayItCore

/// AppConfig unit test: all isolated with a separate UserDefaults(suiteName) to avoid polluting standard.
/// Each case carries its own suiteName + tearDown cleanup, not crossing with each other.
@MainActor
final class AppConfigTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var config: AppConfig!

    override func setUp() {
        super.setUp()
        suiteName = "AppConfigTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        config = AppConfig(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        config = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: Default values

    func testDefaultsOnFreshStore() {
        XCTAssertEqual(config.triggerKey, .rightCommand)
        XCTAssertEqual(config.interactionMode, .singleTap)
        XCTAssertEqual(config.sttMode, .local)
        XCTAssertEqual(config.localModel, "large-v3-turbo")
        XCTAssertEqual(config.cloudSTTModel, "gpt-4o-mini-transcribe")
        XCTAssertTrue(config.polishEnabled)
        XCTAssertTrue(config.soundCuesEnabled)
        XCTAssertEqual(config.polishStyle, .smart)
        XCTAssertEqual(config.providerKind, .openAI)
        XCTAssertEqual(config.model, ProviderKind.openAI.defaultModel)
        XCTAssertEqual(config.language, "auto")
    }

    // MARK: Read/write round-trip (enums)

    func testTriggerKeyRoundTrip() {
        for key in TriggerKey.allCases {
            config.triggerKey = key
            XCTAssertEqual(config.triggerKey, key)
            // Cross-instance persistence: a new AppConfig reading the same store is still that value.
            XCTAssertEqual(AppConfig(defaults: defaults).triggerKey, key)
        }
    }

    func testInteractionModeRoundTrip() {
        config.interactionMode = .hold
        XCTAssertEqual(config.interactionMode, .hold)
        XCTAssertEqual(AppConfig(defaults: defaults).interactionMode, .hold)
        config.interactionMode = .singleTap
        XCTAssertEqual(config.interactionMode, .singleTap)
    }

    func testSTTModeRoundTrip() {
        config.sttMode = .cloud
        XCTAssertEqual(config.sttMode, .cloud)
        XCTAssertEqual(AppConfig(defaults: defaults).sttMode, .cloud)
    }

    func testPolishStyleRoundTrip() {
        for style in PolishStyle.allCases {
            config.polishStyle = style
            XCTAssertEqual(config.polishStyle, style)
            XCTAssertEqual(AppConfig(defaults: defaults).polishStyle, style)
        }
    }

    // MARK: Read/write round-trip (scalar/string)

    func testPolishEnabledRoundTrip() {
        config.polishEnabled = false
        XCTAssertFalse(config.polishEnabled)
        XCTAssertFalse(AppConfig(defaults: defaults).polishEnabled)
        config.polishEnabled = true
        XCTAssertTrue(config.polishEnabled)
    }

    func testSoundCuesEnabledRoundTrip() {
        config.soundCuesEnabled = false
        XCTAssertFalse(config.soundCuesEnabled)
        XCTAssertFalse(AppConfig(defaults: defaults).soundCuesEnabled)
        config.soundCuesEnabled = true
        XCTAssertTrue(config.soundCuesEnabled)
    }

    func testSoundCuesEnabledChangePostsNotification() {
        let exp = expectation(forNotification: AppConfig.didChangeNotification, object: config)
        config.soundCuesEnabled = false
        wait(for: [exp], timeout: 1.0)
    }

    func testLocalModelRoundTrip() {
        config.localModel = "tiny.en"
        XCTAssertEqual(config.localModel, "tiny.en")
        XCTAssertEqual(AppConfig(defaults: defaults).localModel, "tiny.en")
    }

    func testCloudSTTModelRoundTrip() {
        config.cloudSTTModel = "whisper-1"
        XCTAssertEqual(config.cloudSTTModel, "whisper-1")
        XCTAssertEqual(AppConfig(defaults: defaults).cloudSTTModel, "whisper-1")
    }

    func testLanguageRoundTrip() {
        config.language = "zh"
        XCTAssertEqual(config.language, "zh")
        XCTAssertEqual(AppConfig(defaults: defaults).language, "zh")
    }

    // MARK: UI language

    func testUILanguageDefaultsToSystemMapping() {
        // A brand-new store: the default falls back to UILanguage.systemDefault mapped per the system preferred language.
        XCTAssertEqual(config.uiLanguage, UILanguage.systemDefault)
    }

    func testSystemDefaultResolvesToASupportedCase() {
        // systemDefault (the unset-key default) always maps the system preferred language to one of the two
        // supported options; it never produces an out-of-range value regardless of the host locale.
        let resolved = UILanguage.systemDefault
        XCTAssertTrue([.english, .simplifiedChinese].contains(resolved))
        // It must agree with the zh-prefix rule applied to the live preferred language.
        let isChinese = (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
        XCTAssertEqual(resolved, isChinese ? .simplifiedChinese : .english)
    }

    func testUILanguageRoundTrip() {
        for lang in UILanguage.allCases {
            config.uiLanguage = lang
            XCTAssertEqual(config.uiLanguage, lang)
            XCTAssertEqual(AppConfig(defaults: defaults).uiLanguage, lang)
        }
    }

    func testUILanguageUnknownRawFallsBackToSystemDefault() {
        defaults.set("fr", forKey: "ui.language")
        XCTAssertEqual(AppConfig(defaults: defaults).uiLanguage, UILanguage.systemDefault)
    }

    func testUILanguageChangePostsNotification() {
        let target: UILanguage = config.uiLanguage == .english ? .simplifiedChinese : .english
        let exp = expectation(forNotification: AppConfig.didChangeNotification, object: config)
        config.uiLanguage = target
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: Input device UID (nullable)

    func testInputDeviceUIDDefaultsToNil() {
        XCTAssertNil(config.inputDeviceUID)
    }

    func testInputDeviceUIDRoundTrip() {
        config.inputDeviceUID = "BuiltInMicrophoneDevice"
        XCTAssertEqual(config.inputDeviceUID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(AppConfig(defaults: defaults).inputDeviceUID, "BuiltInMicrophoneDevice")
    }

    func testInputDeviceUIDSetNilRemovesKey() {
        config.inputDeviceUID = "SomeDevice"
        XCTAssertNotNil(config.inputDeviceUID)
        config.inputDeviceUID = nil
        XCTAssertNil(config.inputDeviceUID)
        XCTAssertNil(AppConfig(defaults: defaults).inputDeviceUID)
    }

    func testInputDeviceUIDChangePostsNotification() {
        let exp = expectation(forNotification: AppConfig.didChangeNotification, object: config)
        config.inputDeviceUID = "DeviceX"
        wait(for: [exp], timeout: 1.0)
    }

    func testInputDeviceUIDUnchangedDoesNotPost() {
        config.inputDeviceUID = "DeviceX"
        let exp = expectation(forNotification: AppConfig.didChangeNotification, object: config)
        exp.isInverted = true
        config.inputDeviceUID = "DeviceX"
        wait(for: [exp], timeout: 0.3)
    }

    // MARK: providerKind / model coupling behavior

    func testProviderKindRoundTrip() {
        config.providerKind = .anthropic
        XCTAssertEqual(config.providerKind, .anthropic)
        XCTAssertEqual(AppConfig(defaults: defaults).providerKind, .anthropic)
    }

    func testModelRoundTripWithinProvider() {
        // Pick a legal model belonging to openAI.
        let valid = ProviderKind.openAI.modelOptions.map(\.id)
        let pick = valid.last!
        config.providerKind = .openAI
        config.model = pick
        XCTAssertEqual(config.model, pick)
        XCTAssertEqual(AppConfig(defaults: defaults).model, pick)
    }

    func testModelClampsBackToDefaultWhenNotInProvider() {
        // Store a model not belonging to anthropic (borrowing openAI's); after switching to anthropic it should fall back to its default model.
        config.providerKind = .openAI
        config.model = ProviderKind.openAI.defaultModel
        config.providerKind = .anthropic
        XCTAssertEqual(config.model, ProviderKind.anthropic.defaultModel)
    }

    /// Regression guard: a previously-persisted but now-deprecated model id must gracefully clamp to
    /// the current provider's default rather than be served back as an invalid id to the API.
    func testStaleStoredModelClampsToNewDefault() {
        // DeepSeek: a stored legacy "deepseek-chat" must clamp to the new V4 default.
        defaults.set(ProviderKind.deepSeek.rawValue, forKey: "provider.kind")
        defaults.set("deepseek-chat", forKey: "provider.model")
        XCTAssertEqual(AppConfig(defaults: defaults).model, ProviderKind.deepSeek.defaultModel)

        // OpenAI: a stored legacy "gpt-4o-mini" must clamp to the new GPT-5.x default.
        defaults.set(ProviderKind.openAI.rawValue, forKey: "provider.kind")
        defaults.set("gpt-4o-mini", forKey: "provider.model")
        XCTAssertEqual(AppConfig(defaults: defaults).model, ProviderKind.openAI.defaultModel)

        // Anthropic: a stored legacy "claude-3-5-haiku-20241022" must clamp to the new default.
        defaults.set(ProviderKind.anthropic.rawValue, forKey: "provider.kind")
        defaults.set("claude-3-5-haiku-20241022", forKey: "provider.model")
        XCTAssertEqual(AppConfig(defaults: defaults).model, ProviderKind.anthropic.defaultModel)
    }

    // MARK: Silent fallback for corrupt/unknown values

    func testUnknownRawValueFallsBackToDefault() {
        defaults.set("nope-not-a-key", forKey: "trigger.key")
        defaults.set("nope", forKey: "interaction.mode")
        defaults.set("nope", forKey: "stt.mode")
        defaults.set("nope", forKey: "polish.style")
        defaults.set("nope", forKey: "provider.kind")
        let fresh = AppConfig(defaults: defaults)
        XCTAssertEqual(fresh.triggerKey, .rightCommand)
        XCTAssertEqual(fresh.interactionMode, .singleTap)
        XCTAssertEqual(fresh.sttMode, .local)
        XCTAssertEqual(fresh.polishStyle, .smart)
        XCTAssertEqual(fresh.providerKind, .openAI)
    }

    // MARK: Change notification

    func testChangeNotificationPosts() {
        let exp = expectation(forNotification: AppConfig.didChangeNotification, object: config)
        config.sttMode = .cloud
        wait(for: [exp], timeout: 1.0)
    }

    func testNoNotificationWhenValueUnchanged() {
        config.sttMode = .local // already default; setting same value must not post
        let exp = expectation(forNotification: AppConfig.didChangeNotification, object: config)
        exp.isInverted = true
        config.sttMode = .local
        wait(for: [exp], timeout: 0.3)
    }

    // MARK: Does not pollute standard

    func testDoesNotTouchStandardDefaults() {
        let standard = UserDefaults.standard
        let before = standard.string(forKey: "trigger.key")
        config.triggerKey = .leftCommand
        XCTAssertEqual(standard.string(forKey: "trigger.key"), before)
    }
}

@MainActor
final class ConfigEnumTests: XCTestCase {
    func testTriggerKeyDefault() {
        XCTAssertEqual(TriggerKey.default, .rightCommand)
    }

    func testInteractionModeDefault() {
        XCTAssertEqual(InteractionMode.default, .singleTap)
    }

    func testSTTModeDefault() {
        XCTAssertEqual(STTMode.default, .local)
    }

    func testPolishStyleHasAllExpectedCases() {
        XCTAssertEqual(Set(PolishStyle.allCases),
                       [.smart, .punctuationOnly, .formal, .casual])
        XCTAssertEqual(PolishStyle.default, .smart)
    }

    func testProviderKindModelOptionsNonEmpty() {
        for kind in ProviderKind.allCases {
            XCTAssertFalse(kind.modelOptions.isEmpty, "\(kind) has no models")
            XCTAssertFalse(kind.defaultModel.isEmpty, "\(kind) has empty default model")
        }
    }

    /// Regression guard: the ChatGPT-login (Codex) Responses API rejects the legacy gpt-4o ids
    /// with HTTP 400 ("model is not supported when using Codex with a ChatGPT account"). The model
    /// list must only offer Codex GPT-5.x ids (verified live with HTTP 200) and default to GPT-5.5.
    func testChatGPTProviderOffersCurrentCodexModels() {
        let ids = ProviderKind.chatGPT.modelOptions.map(\.id)
        // None of the unsupported legacy ids may be offered.
        XCTAssertFalse(ids.contains("gpt-4o-mini"), "ChatGPT login no longer supports gpt-4o-mini")
        XCTAssertFalse(ids.contains("gpt-4o"), "ChatGPT login no longer supports gpt-4o")
        // Exactly the Codex GPT-5.x ids confirmed available for the ChatGPT login.
        XCTAssertEqual(ids, ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"])
        XCTAssertEqual(ProviderKind.chatGPT.defaultModel, "gpt-5.5")
    }

    /// Regression guard: the DeepSeek API key provider must offer only the current DeepSeek V4
    /// models. The legacy deepseek-chat / deepseek-reasoner ids are deprecated (sunset 2026-07-24)
    /// and must no longer be offered. Default is the faster/cheaper V4 Flash (best for polishing).
    func testDeepSeekProviderOffersCurrentModels() {
        let options = ProviderKind.deepSeek.modelOptions
        let ids = options.map(\.id)
        XCTAssertFalse(ids.contains("deepseek-chat"), "deepseek-chat is deprecated and must be removed")
        XCTAssertFalse(ids.contains("deepseek-reasoner"), "deepseek-reasoner is deprecated and must be removed")
        XCTAssertEqual(ids, ["deepseek-v4-flash", "deepseek-v4-pro"])
        XCTAssertEqual(options.map(\.label), ["DeepSeek V4 Flash", "DeepSeek V4 Pro"])
        XCTAssertEqual(ProviderKind.deepSeek.defaultModel, "deepseek-v4-flash")
    }

    /// Regression guard: the OpenAI API key provider must use current GPT-5.x chat model ids with
    /// bare ids (no date suffix). The legacy gpt-4o / gpt-4o-mini ids must no longer be offered.
    /// Default is the cost-effective gpt-5.4-mini (best for polishing).
    func testOpenAIProviderOffersCurrentModels() {
        let ids = ProviderKind.openAI.modelOptions.map(\.id)
        XCTAssertFalse(ids.contains("gpt-4o"), "gpt-4o must be removed")
        XCTAssertFalse(ids.contains("gpt-4o-mini"), "gpt-4o-mini must be removed")
        XCTAssertTrue(ids.contains("gpt-5.5"), "OpenAI must offer gpt-5.5")
        XCTAssertTrue(ids.contains("gpt-5.4-mini"), "OpenAI must offer gpt-5.4-mini")
        // Bare ids only (no date suffix like -2025-xx-xx).
        for id in ids {
            XCTAssertNil(id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression),
                         "\(id) must be a bare model id without a date suffix")
        }
        XCTAssertEqual(ProviderKind.openAI.defaultModel, "gpt-5.4-mini")
    }

    /// Regression guard: the Anthropic provider must use the current Claude 4.x bare ids (no date
    /// suffix). Legacy claude-3.x ids must no longer be offered. Default is the cheap/fast
    /// claude-haiku-4-5 (best for polishing).
    func testAnthropicProviderOffersCurrentModels() {
        let ids = ProviderKind.anthropic.modelOptions.map(\.id)
        for id in ids {
            XCTAssertFalse(id.hasPrefix("claude-3"), "\(id): claude-3.x must be removed")
            // Bare ids only (no trailing date like -20251001).
            XCTAssertNil(id.range(of: #"-\d{8}$"#, options: .regularExpression),
                         "\(id) must be a bare model id without a date suffix")
        }
        XCTAssertEqual(ids, ["claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-8"])
        XCTAssertEqual(ProviderKind.anthropic.defaultModel, "claude-haiku-4-5")
    }

    /// Regression guard: every provider's default model must be one of its own valid options
    /// (no stale default pointing at a removed id).
    func testEveryProviderDefaultIsAValidOption() {
        for kind in ProviderKind.allCases {
            let ids = kind.modelOptions.map(\.id)
            XCTAssertTrue(ids.contains(kind.defaultModel),
                          "\(kind) default \(kind.defaultModel) is not in its options \(ids)")
        }
    }

    func testUILanguageHasOnlyTwoCases() {
        XCTAssertEqual(Set(UILanguage.allCases), [.english, .simplifiedChinese])
    }

    func testUILanguageRawValuesAreBCP47() {
        XCTAssertEqual(UILanguage.english.rawValue, "en")
        XCTAssertEqual(UILanguage.simplifiedChinese.rawValue, "zh-Hans")
    }

    func testUILanguageDisplayNamesAreSelfNames() {
        XCTAssertEqual(UILanguage.english.displayName, "English")
        XCTAssertEqual(UILanguage.simplifiedChinese.displayName, "简体中文")
    }

    func testUILanguageLocaleMatchesRawValue() {
        for lang in UILanguage.allCases {
            XCTAssertEqual(lang.locale.identifier, lang.rawValue)
        }
    }

    func testUILanguageSystemDefaultIsSupported() {
        XCTAssertTrue(UILanguage.allCases.contains(UILanguage.systemDefault))
    }
}
