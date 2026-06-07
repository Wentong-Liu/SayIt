import Foundation

/// 全局共享应用配置（非密钥项走 UserDefaults；API Key / OAuth token 仍在 Keychain）。
///
/// 参考 ZhiYu 的 `AppConfig` 模式，但字段换成 sayit 的：触发键、交互方式、STT 模式、
/// 本地/云端模型、润色开关与风格、润色用 Provider+模型、语言。
///
/// 设计要点：
/// - **类型安全读写 + 默认值**：每个属性以强类型暴露，缺省/损坏值静默回落到该类型的 `default`。
/// - **可观察**：任一属性写入且值确有变化时，发 ``AppConfig/didChangeNotification``（object 为本实例）。
///   监听方在通知里重新读取所需属性即可，无需关心改了哪一项。
/// - **可注入 `UserDefaults`**：默认用 `.standard`；单测传入独立 suite，避免污染。
@MainActor
public final class AppConfig {
    /// 进程内共享实例（生产用 `UserDefaults.standard`）。
    public static let shared = AppConfig()

    /// 配置发生变化时投递的通知；`object` 为发生变化的 `AppConfig` 实例。
    /// 监听方应在收到后重新读取关心的属性（通知不携带 diff）。
    public static let didChangeNotification = Notification.Name("com.liuwentong.SayIt.AppConfigDidChange")

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    /// - Parameters:
    ///   - defaults: 后端存储；默认 `.standard`，单测传独立 suite。
    ///   - notificationCenter: 变更通知中心；默认 `.default`。
    public init(defaults: UserDefaults = .standard,
                notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    /// 持久化键名。字符串值是落盘键名，**改了会丢已有配置**，不可变。
    private enum Key {
        static let triggerKey = "trigger.key"
        static let interactionMode = "interaction.mode"
        static let sttMode = "stt.mode"
        static let localModel = "stt.localModel"
        static let cloudSTTModel = "stt.cloudModel"
        static let polishEnabled = "polish.enabled"
        static let polishStyle = "polish.style"
        static let providerKind = "provider.kind"
        static let model = "provider.model"
        static let language = "language"
        static let uiLanguage = "ui.language"
        static let inputDeviceUID = "audio.inputDeviceUID"
    }

    // MARK: 触发 / 交互

    /// 触发听写的修饰键。缺省右⌘；监听处实时读它，改了立即生效。
    public var triggerKey: TriggerKey {
        get { enumValue(Key.triggerKey, default: .default) }
        set { setEnum(newValue, forKey: Key.triggerKey) }
    }

    /// 触发交互方式（按住 / 单击切换）。缺省按住说话。
    public var interactionMode: InteractionMode {
        get { enumValue(Key.interactionMode, default: .default) }
        set { setEnum(newValue, forKey: Key.interactionMode) }
    }

    // MARK: STT

    /// 语音转写运行位置（本地 / 云端）。缺省本地。
    public var sttMode: STTMode {
        get { enumValue(Key.sttMode, default: .default) }
        set { setEnum(newValue, forKey: Key.sttMode) }
    }

    /// 本地 STT 模型标识（如 WhisperKit 模型名）。缺省 "large-v3-turbo"。
    public var localModel: String {
        get { stringValue(Key.localModel, default: Self.defaultLocalModel) }
        set { setString(newValue, forKey: Key.localModel) }
    }

    /// 云端 STT 模型标识。缺省 "gpt-4o-mini-transcribe"。
    public var cloudSTTModel: String {
        get { stringValue(Key.cloudSTTModel, default: Self.defaultCloudSTTModel) }
        set { setString(newValue, forKey: Key.cloudSTTModel) }
    }

    // MARK: 润色

    /// 是否对转写结果做 LLM 润色。缺省开。
    public var polishEnabled: Bool {
        get { boolValue(Key.polishEnabled, default: Self.defaultPolishEnabled) }
        set { setBool(newValue, forKey: Key.polishEnabled) }
    }

    /// 润色风格。缺省智能润色。
    public var polishStyle: PolishStyle {
        get { enumValue(Key.polishStyle, default: .default) }
        set { setEnum(newValue, forKey: Key.polishStyle) }
    }

    // MARK: 润色用 Provider / 模型

    /// 润色所用 Provider。缺省 OpenAI。落盘 `rawValue`，未知值静默回落。
    public var providerKind: ProviderKind {
        get { enumValue(Key.providerKind, default: .default) }
        set { setEnum(newValue, forKey: Key.providerKind) }
    }

    /// 润色所用模型 id。读时夹回到当前 `providerKind` 的可选模型：
    /// 落盘的 model 若不属于当前 Provider（例如换过 Provider 没点过模型下拉），
    /// 回落到该 Provider 默认模型，避免把不属于该 Provider 的 model id 发给 API。
    public var model: String {
        get {
            let stored = defaults.string(forKey: Key.model)
            let valid = providerKind.modelOptions.map(\.id)
            if let stored, valid.contains(stored) { return stored }
            return providerKind.defaultModel
        }
        set { setString(newValue, forKey: Key.model) }
    }

    // MARK: 语言

    /// 听写/润色目标语言；"auto" 表示自动跟随转写语言。缺省 "auto"。
    ///
    /// - Note: 自 T24 起语音识别**恒自动检测**（``DictationCoordinator`` 传 `language=nil`），
    ///   此字段不再驱动转写，仅为向后兼容保留（旧版本写入的值不会报错）。
    public var language: String {
        get { stringValue(Key.language, default: Self.defaultLanguage) }
        set { setString(newValue, forKey: Key.language) }
    }

    /// 界面显示语言；取值仅限 ``UILanguage`` 的两项（英文 / 简体中文）。
    ///
    /// 落盘 BCP-47 标识（`"en"` / `"zh-Hans"`）。缺省按系统首选语言映射到二者之一
    /// （中文系 → 简体中文，其余 → 英文），见 ``UILanguage/systemDefault``。
    /// 监听方收到变更通知后重读，并把 `Locale(identifier:)` 应用到根场景以即时重定位 UI。
    public var uiLanguage: UILanguage {
        get { enumValue(Key.uiLanguage, default: UILanguage.systemDefault) }
        set { setEnum(newValue, forKey: Key.uiLanguage) }
    }

    // MARK: 音频输入设备

    /// 选定的麦克风输入设备 UID；`nil` 表示跟随系统默认输入设备。
    ///
    /// 存盘的是 CoreAudio 的设备 UID（``AudioInputDevice/uid``）。设备被拔出后 UID
    /// 解析不到时，``AudioRecorder`` 会自动回落到系统默认设备，故此处无需校验有效性。
    public var inputDeviceUID: String? {
        get { defaults.string(forKey: Key.inputDeviceUID) }
        set { setOptionalString(newValue, forKey: Key.inputDeviceUID) }
    }

    // MARK: 默认常量（单一真相源）

    static let defaultLocalModel = "large-v3-turbo"
    static let defaultCloudSTTModel = "gpt-4o-mini-transcribe"
    static let defaultPolishEnabled = true
    static let defaultLanguage = "auto"

    // MARK: 通用读写 + 变更通知

    /// 读枚举：缺省/损坏值静默回落到 `fallback`。
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

    /// 读字符串：未设置时回落到 `fallback`。
    private func stringValue(_ key: String, default fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private func setString(_ newValue: String, forKey key: String) {
        guard defaults.string(forKey: key) != newValue else { return }
        defaults.set(newValue, forKey: key)
        postChange()
    }

    /// 写可空字符串：`nil` 时移除键（表达「未设置/跟随默认」），值未变则不发通知。
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

    /// 读布尔：未设置时回落到 `fallback`（区分「未设置」与「显式 false」）。
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
