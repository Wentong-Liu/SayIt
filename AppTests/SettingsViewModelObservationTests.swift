import Observation
import XCTest
@testable import SayIt
@testable import SayItCore

/// Regression tests for the "Settings Picker shows the OLD value after you change it" bug.
///
/// Root cause: `SettingsViewModel` is `@Observable`, but its config-backed properties were
/// declared as *computed* `get`/`set` forwarding to `AppConfig` (a plain, non-`@Observable`
/// class). The `@Observable` macro only injects Observation tracking (`access` in the getter,
/// `withMutation` in the setter) for **stored** properties — computed properties get none.
/// So a Picker bound to e.g. `$viewModel.triggerKey` wrote the new value through to `AppConfig`
/// (the change *applied* and *persisted*), but SwiftUI was never told the property changed, so
/// the view was not invalidated and the Picker kept rendering the OLD selection (no checkmark
/// move). The `sttMode` property worked because it was a *stored* mirror.
///
/// These tests model SwiftUI's invalidation with `withObservationTracking`: reading a property
/// inside the `apply` block must register it for tracking, and a subsequent write must fire the
/// `onChange` callback. If it does not fire, SwiftUI would likewise not re-render — that is the
/// bug. Each test also asserts the value actually applies and persists (write-through to config).
@MainActor
final class SettingsViewModelObservationTests: XCTestCase {

    /// An isolated `AppConfig` on a throwaway `UserDefaults` suite (never touches `.standard`).
    /// Optionally injects a private `NotificationCenter` so a test can assert/deny a posted change
    /// without being fooled by unrelated `.default` traffic.
    private func makeConfig(notificationCenter: NotificationCenter = .default) -> AppConfig {
        let suite = "test.settingsvm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return AppConfig(defaults: defaults, notificationCenter: notificationCenter)
    }

    /// Reads `read()` once under observation tracking, then runs `mutate()` and asserts the
    /// tracked read property fired its change notification — i.e. SwiftUI would re-render.
    /// Returns whether the change callback fired (so callers can assert it).
    private func assertObservationFires(
        read: @escaping () -> Void,
        mutate: () -> Void,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let didChange = expectation(description: message)
        withObservationTracking {
            read()
        } onChange: {
            didChange.fulfill()
        }
        mutate()
        wait(for: [didChange], timeout: 1.0)
    }

    // MARK: - General

    func testTriggerKeyChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let original = vm.triggerKey
        let next = TriggerKey.allCases.first { $0 != original }!

        assertObservationFires(read: { _ = vm.triggerKey }, mutate: { vm.triggerKey = next },
                               "triggerKey change should invalidate the view")
        XCTAssertEqual(vm.triggerKey, next, "new value should be reflected")
        XCTAssertEqual(config.triggerKey, next, "new value should persist to config")
    }

    func testInteractionModeChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let original = vm.interactionMode
        let next = InteractionMode.allCases.first { $0 != original }!

        assertObservationFires(read: { _ = vm.interactionMode }, mutate: { vm.interactionMode = next },
                               "interactionMode change should invalidate the view")
        XCTAssertEqual(vm.interactionMode, next)
        XCTAssertEqual(config.interactionMode, next)
    }

    func testUILanguageChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let original = vm.uiLanguage
        let next = UILanguage.allCases.first { $0 != original }!

        assertObservationFires(read: { _ = vm.uiLanguage }, mutate: { vm.uiLanguage = next },
                               "uiLanguage change should invalidate the view")
        XCTAssertEqual(vm.uiLanguage, next)
        XCTAssertEqual(config.uiLanguage, next)
    }

    func testSoundCuesEnabledChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let original = vm.soundCuesEnabled

        assertObservationFires(read: { _ = vm.soundCuesEnabled }, mutate: { vm.soundCuesEnabled = !original },
                               "soundCuesEnabled change should invalidate the view")
        XCTAssertEqual(vm.soundCuesEnabled, !original)
        XCTAssertEqual(config.soundCuesEnabled, !original)
    }

    // MARK: - STT

    func testSTTModeChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let original = vm.sttMode
        let next = STTMode.allCases.first { $0 != original }!

        assertObservationFires(read: { _ = vm.sttMode }, mutate: { vm.sttMode = next },
                               "sttMode change should invalidate the view")
        XCTAssertEqual(vm.sttMode, next)
        XCTAssertEqual(config.sttMode, next)
    }

    // The local model is fixed to large-v3-turbo (the picker and its observable mirror were removed),
    // so there is no longer a local-model observation/persistence test here. Its "fixed model" behavior
    // is covered by AppConfigTests.testLocalModelIsAlwaysTurbo.

    func testCloudSTTModelChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let next = vm.cloudSTTModelOptions.map(\.id).first { $0 != vm.cloudSTTModel }!

        assertObservationFires(read: { _ = vm.cloudSTTModel }, mutate: { vm.cloudSTTModel = next },
                               "cloudSTTModel change should invalidate the view")
        XCTAssertEqual(vm.cloudSTTModel, next)
        XCTAssertEqual(config.cloudSTTModel, next)
    }

    /// A successful cloud-key save must post `AppConfig.didChangeNotification` so the coordinator refreshes its
    /// cached cloud key and a same-model key-only re-save takes effect on the next dictation.
    /// `KeychainStore` is a static enum with no injection point, so this writes the real login Keychain; the
    /// original value is saved/restored and the assertion is skipped if the sandboxed Keychain write fails.
    func testSaveCloudSTTAPIKeySuccessPostsChange() throws {
        let center = NotificationCenter()
        let config = makeConfig(notificationCenter: center)
        let vm = SettingsViewModel(config: config)

        // Restore whatever was there before (empty string when nothing existed; the cloud-key reader trims and
        // treats an empty string as "no key", so this never clobbers a real developer key).
        let original = KeychainStore.get(account: KeychainStore.Account.openAIAPIKey)
        defer { _ = KeychainStore.set(original ?? "", account: KeychainStore.Account.openAIAPIKey) }

        let testKey = "sk-test-\(UUID().uuidString)"
        try XCTSkipUnless(KeychainStore.set(testKey, account: KeychainStore.Account.openAIAPIKey),
                          "Sandboxed Keychain write unavailable; cannot exercise the success path.")

        vm.cloudSTTAPIKey = testKey
        let exp = expectation(forNotification: AppConfig.didChangeNotification, object: config,
                              notificationCenter: center)
        vm.saveCloudSTTAPIKey()
        wait(for: [exp], timeout: 1.0)
    }

    /// An empty/whitespace cloud-key save is a no-op (early return, no Keychain write) and must NOT post.
    func testSaveCloudSTTAPIKeyEmptyDoesNotPost() {
        let center = NotificationCenter()
        let config = makeConfig(notificationCenter: center)
        let vm = SettingsViewModel(config: config)

        vm.cloudSTTAPIKey = "   "
        let exp = expectation(forNotification: AppConfig.didChangeNotification, object: config,
                              notificationCenter: center)
        exp.isInverted = true
        vm.saveCloudSTTAPIKey()
        wait(for: [exp], timeout: 0.3)
    }

    // MARK: - Polish

    func testPolishStyleChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let original = vm.polishStyle
        let next = PolishStyle.allCases.first { $0 != original }!

        assertObservationFires(read: { _ = vm.polishStyle }, mutate: { vm.polishStyle = next },
                               "polishStyle change should invalidate the view")
        XCTAssertEqual(vm.polishStyle, next)
        XCTAssertEqual(config.polishStyle, next)
    }

    func testProviderKindChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let original = vm.providerKind
        let next = ProviderKind.allCases.first { $0 != original }!

        assertObservationFires(read: { _ = vm.providerKind }, mutate: { vm.providerKind = next },
                               "providerKind change should invalidate the view")
        XCTAssertEqual(vm.providerKind, next)
        XCTAssertEqual(config.providerKind, next)
        // Switching provider clamps the model to that provider's default (UI consistency).
        XCTAssertEqual(vm.model, next.defaultModel)
    }

    func testPolishModelChangeFiresObservationAndPersists() throws {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        // Stay on the current provider; pick a second model id from its options.
        let ids = vm.providerKind.modelOptions.map(\.id)
        guard let next = ids.first(where: { $0 != vm.model }) else {
            throw XCTSkip("Current provider exposes only one model; nothing to switch to.")
        }

        assertObservationFires(read: { _ = vm.model }, mutate: { vm.model = next },
                               "polish model change should invalidate the view")
        XCTAssertEqual(vm.model, next)
        XCTAssertEqual(config.model, next)
    }

    func testPolishEnabledChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let original = vm.polishEnabled

        assertObservationFires(read: { _ = vm.polishEnabled }, mutate: { vm.polishEnabled = !original },
                               "polishEnabled change should invalidate the view")
        XCTAssertEqual(vm.polishEnabled, !original)
        XCTAssertEqual(config.polishEnabled, !original)
    }

    // MARK: - Setup affordances (size disclosure + polish-unconfigured warning)

    /// The Speech-pane size note must never hardcode "1.6 GB": `estimatedLocalModelBytes` must mirror the
    /// existing `ModelManager.estimatedDownloadBytes` estimate for the fixed local model (turbo → 1.6 GB).
    func testEstimatedLocalModelBytesMirrorsModelManager() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let expected = Int64(ModelManager.estimatedDownloadBytes(for: config.localModel))
        XCTAssertEqual(vm.estimatedLocalModelBytes, expected)
        // The local model is fixed to turbo, whose estimate is 1.6 GB (1.6e9 bytes).
        XCTAssertEqual(vm.estimatedLocalModelBytes, 1_600_000_000)
    }

    /// When polish is OFF, no provider should ever report a setup warning (nothing to warn about).
    func testPolishDisabledNeverWarnsForAnyProvider() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        vm.polishEnabled = false
        for kind in ProviderKind.allCases {
            vm.providerKind = kind
            XCTAssertFalse(vm.polishNeedsSetup, "\(kind): disabled polish must not need setup")
            XCTAssertNil(vm.polishSetupWarningKey, "\(kind): disabled polish must have no warning key")
        }
    }

    /// BYO providers: an empty key → not configured → warns with the API-key key; a present key → configured → no warning.
    /// Drives the live `polishAPIKey` buffer (the Keychain mirror) — no Keychain write needed.
    func testPolishBYOProvidersWarnWhenKeyMissingAndClearWhenSet() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        vm.polishEnabled = true
        for kind in ProviderKind.allCases where kind != .chatGPT {
            vm.providerKind = kind

            // Empty key (whitespace counts as empty) → needs setup, API-key warning.
            vm.polishAPIKey = "   "
            XCTAssertFalse(vm.polishBYOKeyPresent, "\(kind): whitespace key is not present")
            XCTAssertFalse(vm.polishIsConfigured, "\(kind): empty key is not configured")
            XCTAssertTrue(vm.polishNeedsSetup, "\(kind): empty key + enabled needs setup")
            XCTAssertEqual(vm.polishSetupWarningKey, "polish.setupWarning.apiKey",
                           "\(kind): empty BYO key must show the API-key warning")

            // Present key → configured, no warning.
            vm.polishAPIKey = "sk-test-key"
            XCTAssertTrue(vm.polishBYOKeyPresent, "\(kind): non-empty key is present")
            XCTAssertTrue(vm.polishIsConfigured, "\(kind): saved key is configured")
            XCTAssertFalse(vm.polishNeedsSetup, "\(kind): configured key needs no setup")
            XCTAssertNil(vm.polishSetupWarningKey, "\(kind): configured key has no warning key")
        }
    }

    /// ChatGPT (OAuth) provider: the warning gate is `isChatGPTLoggedIn` (private(set), defaults to the
    /// real Keychain state). On a sandboxed test runner with no ChatGPT token, the default is "not signed
    /// in", so enabling polish on ChatGPT must surface the sign-in warning (not the API-key one). When the
    /// runner happens to have a real token, the branch is configured instead — assert accordingly so the
    /// test is robust to either Keychain state while still proving the OAuth-vs-BYO key selection.
    func testPolishChatGPTWarnsWithSignInKeyWhenNotLoggedIn() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        vm.polishEnabled = true
        vm.providerKind = .chatGPT
        XCTAssertTrue(vm.providerUsesOAuth)

        if vm.isChatGPTLoggedIn {
            // A real token exists on this runner: configured, no warning.
            XCTAssertTrue(vm.polishIsConfigured)
            XCTAssertFalse(vm.polishNeedsSetup)
            XCTAssertNil(vm.polishSetupWarningKey)
        } else {
            // The common new-user state: enabled + not signed in → sign-in warning (NOT the API-key one).
            XCTAssertFalse(vm.polishIsConfigured)
            XCTAssertTrue(vm.polishNeedsSetup)
            XCTAssertEqual(vm.polishSetupWarningKey, "polish.setupWarning.signIn")
        }
    }

    /// The warning must react to provider switches: leaving a BYO provider with a saved key for ChatGPT
    /// (not signed in) flips the warning key from nil to the sign-in variant.
    func testPolishWarningReactsToProviderSwitch() throws {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        vm.polishEnabled = true

        // Configure a BYO provider with a key → no warning.
        vm.providerKind = .openAI
        vm.polishAPIKey = "sk-test-key"
        XCTAssertNil(vm.polishSetupWarningKey)

        // Switch to ChatGPT; only meaningful when the runner is not signed in.
        vm.providerKind = .chatGPT
        try XCTSkipIf(vm.isChatGPTLoggedIn, "Runner has a real ChatGPT token; sign-in branch not exercised.")
        XCTAssertEqual(vm.polishSetupWarningKey, "polish.setupWarning.signIn",
                       "switching to ChatGPT while signed out must surface the sign-in warning")
    }

    // MARK: - Tag identity guard

    /// Picker option `.tag()` identity must match the persisted value. The views tag enum options
    /// with the enum case (stable) and model options with the stable `id` (rawValue / api id),
    /// NOT the localized display label. This guards against T33-style localization regressions
    /// where someone might tag with `displayName`/`localizationKey` and break selection matching.
    func testPickerTagIdentityMatchesPersistedValue() {
        // Enum-backed pickers: every case round-trips through its rawValue.
        for key in TriggerKey.allCases {
            XCTAssertEqual(TriggerKey(rawValue: key.rawValue), key)
        }
        for mode in InteractionMode.allCases {
            XCTAssertEqual(InteractionMode(rawValue: mode.rawValue), mode)
        }
        for style in PolishStyle.allCases {
            XCTAssertEqual(PolishStyle(rawValue: style.rawValue), style)
        }
        for kind in ProviderKind.allCases {
            XCTAssertEqual(ProviderKind(rawValue: kind.rawValue), kind)
        }
        // Model-id pickers: the persisted default is always present among the tagged option ids.
        for kind in ProviderKind.allCases {
            let ids = kind.modelOptions.map(\.id)
            XCTAssertTrue(ids.contains(kind.defaultModel),
                          "\(kind) defaultModel must be a selectable option id")
        }
    }
}
