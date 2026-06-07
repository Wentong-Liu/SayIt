import XCTest
@testable import SayItCore

/// AppConfig 单测：全部用独立 UserDefaults(suiteName) 隔离，避免污染 standard。
/// 每个用例自带 suiteName + tearDown 清理，互不串台。
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

    // MARK: 默认值

    func testDefaultsOnFreshStore() {
        XCTAssertEqual(config.triggerKey, .rightCommand)
        XCTAssertEqual(config.interactionMode, .singleTap)
        XCTAssertEqual(config.sttMode, .local)
        XCTAssertEqual(config.localModel, "large-v3-turbo")
        XCTAssertEqual(config.cloudSTTModel, "gpt-4o-mini-transcribe")
        XCTAssertTrue(config.polishEnabled)
        XCTAssertEqual(config.polishStyle, .smart)
        XCTAssertEqual(config.providerKind, .openAI)
        XCTAssertEqual(config.model, ProviderKind.openAI.defaultModel)
        XCTAssertEqual(config.language, "auto")
    }

    // MARK: 读写往返（枚举）

    func testTriggerKeyRoundTrip() {
        for key in TriggerKey.allCases {
            config.triggerKey = key
            XCTAssertEqual(config.triggerKey, key)
            // 跨实例持久化：新建 AppConfig 读同一 store 仍是该值。
            XCTAssertEqual(AppConfig(defaults: defaults).triggerKey, key)
        }
    }

    func testInteractionModeRoundTrip() {
        config.interactionMode = .toggle
        XCTAssertEqual(config.interactionMode, .toggle)
        XCTAssertEqual(AppConfig(defaults: defaults).interactionMode, .toggle)
        config.interactionMode = .hold
        XCTAssertEqual(config.interactionMode, .hold)
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

    // MARK: 读写往返（标量/字符串）

    func testPolishEnabledRoundTrip() {
        config.polishEnabled = false
        XCTAssertFalse(config.polishEnabled)
        XCTAssertFalse(AppConfig(defaults: defaults).polishEnabled)
        config.polishEnabled = true
        XCTAssertTrue(config.polishEnabled)
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

    // MARK: UI 语言

    func testUILanguageDefaultsToSystemMapping() {
        // 全新 store：缺省回落到按系统首选语言映射的 UILanguage.systemDefault。
        XCTAssertEqual(config.uiLanguage, UILanguage.systemDefault)
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

    // MARK: 输入设备 UID（可空）

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

    // MARK: providerKind / model 的耦合行为

    func testProviderKindRoundTrip() {
        config.providerKind = .anthropic
        XCTAssertEqual(config.providerKind, .anthropic)
        XCTAssertEqual(AppConfig(defaults: defaults).providerKind, .anthropic)
    }

    func testModelRoundTripWithinProvider() {
        // 选一个属于 openAI 的合法模型。
        let valid = ProviderKind.openAI.modelOptions.map(\.id)
        let pick = valid.last!
        config.providerKind = .openAI
        config.model = pick
        XCTAssertEqual(config.model, pick)
        XCTAssertEqual(AppConfig(defaults: defaults).model, pick)
    }

    func testModelClampsBackToDefaultWhenNotInProvider() {
        // 存入一个不属于 anthropic 的模型（borrow openAI 的），切到 anthropic 后应回落其默认模型。
        config.providerKind = .openAI
        config.model = ProviderKind.openAI.defaultModel
        config.providerKind = .anthropic
        XCTAssertEqual(config.model, ProviderKind.anthropic.defaultModel)
    }

    // MARK: 损坏/未知值的静默回落

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

    // MARK: 变更通知

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

    // MARK: 不污染 standard

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
