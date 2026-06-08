import Foundation

/// Globally shared application config (non-secret items go through UserDefaults; API Key / OAuth token still live in the Keychain).
///
/// Refers to ZhiYu's `AppConfig` pattern, but with sayit's fields instead: trigger key, interaction style, STT mode,
/// local/cloud model, polish toggle and style, polish Provider+model, language.
///
/// Design points:
/// - **Type-safe read/write + default value**: each property is exposed with a strong type, missing/corrupt values silently fall back to that type's `default`.
/// - **Observable**: when any property is written and the value actually changes, posts ``AppConfig/didChangeNotification`` (object is this instance).
///   Listeners just re-read the needed properties in the notification, without caring which one changed.
/// - **Injectable `UserDefaults`**: defaults to `.standard`; unit tests pass an isolated suite to avoid contamination.
@MainActor
public final class AppConfig {
    /// In-process shared instance (production uses `UserDefaults.standard`).
    public static let shared = AppConfig()

    /// The notification posted when config changes; `object` is the changed `AppConfig` instance.
    /// Listeners should re-read the properties they care about after receiving it (the notification carries no diff).
    public static let didChangeNotification = Notification.Name("com.liuwentong.SayIt.AppConfigDidChange")

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    /// - Parameters:
    ///   - defaults: the backing store; defaults to `.standard`, unit tests pass an isolated suite.
    ///   - notificationCenter: the change-notification center; defaults to `.default`.
    public init(defaults: UserDefaults = .standard,
                notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    /// Persistence key names. The string values are the persisted key names, **changing them loses existing config**, immutable.
    private enum Key {
        static let triggerKey = "trigger.key"
        static let interactionMode = "interaction.mode"
        static let sttMode = "stt.mode"
        static let localModel = "stt.localModel"
        static let cloudSTTModel = "stt.cloudModel"
        static let polishEnabled = "polish.enabled"
        static let polishStyle = "polish.style"
        static let soundCuesEnabled = "sound.cuesEnabled"
        static let learnFromEditsEnabled = "learn.fromEdits.enabled"
        static let providerKind = "provider.kind"
        static let model = "provider.model"
        static let language = "language"
        static let uiLanguage = "ui.language"
        static let inputDeviceUID = "audio.inputDeviceUID"
    }

    // MARK: Trigger / interaction

    /// The modifier key that triggers dictation. Defaults to the right Command; the listener reads it live, changes take effect immediately.
    public var triggerKey: TriggerKey {
        get { enumValue(Key.triggerKey, default: .default) }
        set { setEnum(newValue, forKey: Key.triggerKey) }
    }

    /// The trigger interaction style (tap to toggle / hold to talk). Defaults to tap to toggle.
    public var interactionMode: InteractionMode {
        get { enumValue(Key.interactionMode, default: .default) }
        set { setEnum(newValue, forKey: Key.interactionMode) }
    }

    // MARK: STT

    /// Where speech transcription runs (local / cloud). Defaults to local.
    public var sttMode: STTMode {
        get { enumValue(Key.sttMode, default: .default) }
        set { setEnum(newValue, forKey: Key.sttMode) }
    }

    /// The local STT model identifier (e.g. the WhisperKit model name). Defaults to "large-v3-turbo".
    public var localModel: String {
        get { stringValue(Key.localModel, default: Self.defaultLocalModel) }
        set { setString(newValue, forKey: Key.localModel) }
    }

    /// The cloud STT model identifier. Defaults to "gpt-4o-mini-transcribe".
    public var cloudSTTModel: String {
        get { stringValue(Key.cloudSTTModel, default: Self.defaultCloudSTTModel) }
        set { setString(newValue, forKey: Key.cloudSTTModel) }
    }

    // MARK: Polish

    /// Whether to apply LLM polish to the transcription result. Defaults to on.
    public var polishEnabled: Bool {
        get { boolValue(Key.polishEnabled, default: Self.defaultPolishEnabled) }
        set { setBool(newValue, forKey: Key.polishEnabled) }
    }

    /// The polish style. Defaults to smart polish.
    public var polishStyle: PolishStyle {
        get { enumValue(Key.polishStyle, default: .default) }
        set { setEnum(newValue, forKey: Key.polishStyle) }
    }

    // MARK: Sound cues

    /// Whether to play the start/stop chime cues on dictation (ascending when recording begins, descending when it ends). Defaults to on.
    public var soundCuesEnabled: Bool {
        get { boolValue(Key.soundCuesEnabled, default: Self.defaultSoundCuesEnabled) }
        set { setBool(newValue, forKey: Key.soundCuesEnabled) }
    }

    // MARK: Learn from edits

    /// Whether SayIt may learn new dictionary words from the user's in-place corrections of dictated text.
    ///
    /// Defaults to **OFF** (privacy-conservative). As of this PR this flag is a settings-only opt-in placeholder:
    /// nothing in the live dictation pipeline reads it yet (live edit detection + entry persistence land in the next Part-B PR).
    public var learnFromEditsEnabled: Bool {
        get { boolValue(Key.learnFromEditsEnabled, default: Self.defaultLearnFromEditsEnabled) }
        set { setBool(newValue, forKey: Key.learnFromEditsEnabled) }
    }

    // MARK: Polish Provider / model

    /// The Provider used for polish. Defaults to OpenAI. Persists `rawValue`, unknown values silently fall back.
    public var providerKind: ProviderKind {
        get { enumValue(Key.providerKind, default: .default) }
        set { setEnum(newValue, forKey: Key.providerKind) }
    }

    /// The model id used for polish. On read it is clamped back to the current `providerKind`'s selectable models:
    /// if the persisted model does not belong to the current Provider (e.g. the Provider was switched without touching the model dropdown),
    /// it falls back to that Provider's default model, avoiding sending a model id that does not belong to that Provider to the API.
    public var model: String {
        get {
            let stored = defaults.string(forKey: Key.model)
            let valid = providerKind.modelOptions.map(\.id)
            if let stored, valid.contains(stored) { return stored }
            return providerKind.defaultModel
        }
        set { setString(newValue, forKey: Key.model) }
    }

    // MARK: Language

    /// The dictation/polish target language; "auto" means automatically follow the transcription language. Defaults to "auto".
    ///
    /// - Note: since T24, speech recognition is **always auto-detected** (``DictationCoordinator`` passes `language=nil`),
    ///   this field no longer drives transcription and is kept only for backward compatibility (values written by old versions do not cause errors).
    public var language: String {
        get { stringValue(Key.language, default: Self.defaultLanguage) }
        set { setString(newValue, forKey: Key.language) }
    }

    /// The UI display language; values are limited to ``UILanguage``'s two options (English / Simplified Chinese).
    ///
    /// Persists the BCP-47 identifier (`"en"` / `"zh-Hans"`). Defaults by mapping the system preferred language to one of the two
    /// (Chinese systems -> Simplified Chinese, others -> English), see ``UILanguage/systemDefault``.
    /// Listeners re-read after receiving the change notification and apply `Locale(identifier:)` to the root scene to instantly relocalize the UI.
    public var uiLanguage: UILanguage {
        get { enumValue(Key.uiLanguage, default: UILanguage.systemDefault) }
        set { setEnum(newValue, forKey: Key.uiLanguage) }
    }

    // MARK: Audio input device

    /// The selected microphone input device UID; `nil` means follow the system default input device.
    ///
    /// Persists the CoreAudio device UID (``AudioInputDevice/uid``). After the device is unplugged and the UID
    /// cannot be resolved, ``AudioRecorder`` automatically falls back to the system default device, so no validity check is needed here.
    public var inputDeviceUID: String? {
        get { defaults.string(forKey: Key.inputDeviceUID) }
        set { setOptionalString(newValue, forKey: Key.inputDeviceUID) }
    }

    // MARK: Default constants (single source of truth)

    static let defaultLocalModel = "large-v3-turbo"
    static let defaultCloudSTTModel = "gpt-4o-mini-transcribe"
    static let defaultPolishEnabled = true
    static let defaultSoundCuesEnabled = true
    static let defaultLearnFromEditsEnabled = false
    static let defaultLanguage = "auto"

    // MARK: Generic read/write + change notification

    /// Read an enum: missing/corrupt values silently fall back to `fallback`.
    private func enumValue<E: RawRepresentable>(_ key: String, default fallback: E) -> E
    where E.RawValue == String {
        guard let raw = defaults.string(forKey: key), let value = E(rawValue: raw) else {
            return fallback
        }
        return value
    }

    private func setEnum<E: RawRepresentable>(_ newValue: E, forKey key: String)
    where E.RawValue == String {
        let old = defaults.string(forKey: key)
        guard old != newValue.rawValue else { return }
        defaults.set(newValue.rawValue, forKey: key)
        postChange()
    }

    /// Read a string: falls back to `fallback` when not set.
    private func stringValue(_ key: String, default fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private func setString(_ newValue: String, forKey key: String) {
        guard defaults.string(forKey: key) != newValue else { return }
        defaults.set(newValue, forKey: key)
        postChange()
    }

    /// Write a nullable string: `nil` removes the key (expressing "not set/follow default"), no notification is posted if the value is unchanged.
    private func setOptionalString(_ newValue: String?, forKey key: String) {
        let old = defaults.string(forKey: key)
        guard old != newValue else { return }
        if let newValue {
            defaults.set(newValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        postChange()
    }

    /// Read a bool: falls back to `fallback` when not set (distinguishing "not set" from "explicit false").
    private func boolValue(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func setBool(_ newValue: Bool, forKey key: String) {
        let unchanged = defaults.object(forKey: key) != nil && defaults.bool(forKey: key) == newValue
        guard !unchanged else { return }
        defaults.set(newValue, forKey: key)
        postChange()
    }

    private func postChange() {
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }
}
