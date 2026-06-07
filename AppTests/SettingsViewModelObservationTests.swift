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
    private func makeConfig() -> AppConfig {
        let suite = "test.settingsvm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return AppConfig(defaults: defaults)
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

    func testLocalModelChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        // Pick a candidate id that differs from the current one.
        let next = vm.localModelOptions.map(\.id).first { $0 != vm.localModel }!

        assertObservationFires(read: { _ = vm.localModel }, mutate: { vm.localModel = next },
                               "localModel change should invalidate the view")
        XCTAssertEqual(vm.localModel, next)
        XCTAssertEqual(config.localModel, next)
    }

    func testCloudSTTModelChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = SettingsViewModel(config: config)
        let next = vm.cloudSTTModelOptions.map(\.id).first { $0 != vm.cloudSTTModel }!

        assertObservationFires(read: { _ = vm.cloudSTTModel }, mutate: { vm.cloudSTTModel = next },
                               "cloudSTTModel change should invalidate the view")
        XCTAssertEqual(vm.cloudSTTModel, next)
        XCTAssertEqual(config.cloudSTTModel, next)
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
