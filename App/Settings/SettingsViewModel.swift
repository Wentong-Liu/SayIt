import Observation
import SwiftUI
import SayItCore

/// 设置界面的视图模型：把已有 ``AppConfig``（UserDefaults 持久化）与 ``KeychainStore``（密钥）
/// 桥接成 SwiftUI 可绑定的属性，并负责权限状态查询、ChatGPT OAuth 登录编排。
///
/// 设计要点：
/// - **不重复声明任何配置类型**：触发键 / 交互模式 / STT 模式 / 润色风格 / Provider 均复用
///   `SayItCore` 的单一真相源枚举。本类型只做读写桥接与 UI 编排。
/// - **非密钥项**经 `AppConfig` 落 UserDefaults；**API Key / OAuth token** 经 `KeychainStore` 落钥匙串。
/// - **只读写设置/凭据**，不做端到端听写编排（那属于 T13）。
@MainActor
@Observable
final class SettingsViewModel {
    /// 共享配置（生产用 `AppConfig.shared`）。非 observable：每个属性 get/set 直接转发到它。
    @ObservationIgnored private let config: AppConfig

    /// 本地模型下载/状态管理器。其 `state` 为 `@Observable`，UI 可直接观察其属性驱动刷新。
    let modelManager: ModelManager

    /// - Parameters:
    ///   - config: 注入的配置；默认 `.shared`，单测/预览可传独立实例。
    ///   - modelManager: 注入的本地模型管理器；默认按当前 `localModel` 新建。
    init(config: AppConfig = .shared, modelManager: ModelManager? = nil) {
        self.config = config
        self.modelManager = modelManager ?? ModelManager(model: config.localModel)
        // 初次进入面板时同步一次密钥与权限状态。
        reloadCredentials()
        refreshPermissions()
    }

    // MARK: 通用

    /// 触发听写的修饰键。
    var triggerKey: TriggerKey {
        get { config.triggerKey }
        set { config.triggerKey = newValue }
    }

    /// 触发交互方式（按住 / 单击切换）。
    var interactionMode: InteractionMode {
        get { config.interactionMode }
        set { config.interactionMode = newValue }
    }

    /// 界面显示语言（English / 简体中文）。切换后立即写盘并发通知，根场景据此重定位 UI。
    /// 语音识别**不再**由此（或旧 `language`）字段驱动，恒自动检测（见 ``DictationCoordinator``）。
    var uiLanguage: UILanguage {
        get { config.uiLanguage }
        set { config.uiLanguage = newValue }
    }

    /// 界面语言可选项（仅英文与简体中文）；展示名为该语言自称，不本地化。
    let uiLanguageOptions: [UILanguage] = UILanguage.allCases

    // MARK: STT

    /// 语音转写运行位置（本地 / 云端）。
    var sttMode: STTMode {
        get { config.sttMode }
        set { config.sttMode = newValue }
    }

    /// 本地 STT 模型标识。写入时同步让 ``modelManager`` 切到该模型并按本地缓存刷新状态。
    var localModel: String {
        get { config.localModel }
        set {
            config.localModel = newValue
            modelManager.setModel(newValue)
        }
    }

    // MARK: 本地模型下载

    /// 当前本地模型的下载/缓存状态（由 ``ModelManager`` 实时维护，供 UI 观察）。
    var localModelState: ModelManager.State { modelManager.state }

    /// 进入设置页时按当前模型的本地缓存实况刷新下载状态（不联网、不下载）。
    func refreshLocalModelState() {
        modelManager.setModel(config.localModel)
        modelManager.refreshState()
    }

    /// 触发下载当前本地模型。
    /// - Parameter force: 为 `true` 时即便已缓存也重新下载（「重新下载/重试」用）。
    func downloadLocalModel(force: Bool = false) async {
        await modelManager.download(force: force)
    }

    /// 取消进行中的本地模型下载。
    func cancelLocalModelDownload() {
        modelManager.cancelDownload()
    }

    /// 云端 STT 模型标识。
    var cloudSTTModel: String {
        get { config.cloudSTTModel }
        set { config.cloudSTTModel = newValue }
    }

    /// 本地模型候选：(id, 展示名)。WhisperKit 常见量化模型，默认 large-v3-turbo。
    /// 计算属性：展示名里的描述词随当前界面语言本地化（每次取用时构建，切语言即时生效）。
    var localModelOptions: [(id: String, label: String)] {
        [
            ("large-v3-turbo", String(localized: "model.large-v3-turbo", defaultValue: "large-v3-turbo (recommended)")),
            ("large-v3", String(localized: "model.large-v3", defaultValue: "large-v3 (highest accuracy)")),
            ("medium", String(localized: "model.medium", defaultValue: "medium (balanced)")),
            ("small", String(localized: "model.small", defaultValue: "small (lightweight)")),
            ("base", String(localized: "model.base", defaultValue: "base (fastest)")),
        ]
    }

    /// 云端转写模型候选：(id, 展示名)。当前以 OpenAI transcribe 系列为主。
    let cloudSTTModelOptions: [(id: String, label: String)] = [
        ("gpt-4o-mini-transcribe", "GPT-4o mini transcribe"),
        ("gpt-4o-transcribe", "GPT-4o transcribe"),
        ("whisper-1", "Whisper v1"),
    ]

    // MARK: 润色

    /// 是否对转写结果做 LLM 润色。
    var polishEnabled: Bool {
        get { config.polishEnabled }
        set { config.polishEnabled = newValue }
    }

    /// 润色风格。
    var polishStyle: PolishStyle {
        get { config.polishStyle }
        set { config.polishStyle = newValue }
    }

    /// 润色所用 Provider。切换 Provider 后把模型夹回该 Provider 默认模型，避免发错 model id。
    var providerKind: ProviderKind {
        get { config.providerKind }
        set {
            config.providerKind = newValue
            // `AppConfig.model` 读时会夹回当前 Provider 默认模型；写一次默认值确保 UI 即时一致。
            config.model = newValue.defaultModel
        }
    }

    /// 润色所用模型 id。
    var model: String {
        get { config.model }
        set { config.model = newValue }
    }

    // MARK: 凭据（Keychain）

    /// 云端 STT（OpenAI transcribe）所用 API Key 的录入缓冲。失焦/保存时写 Keychain。
    var cloudSTTAPIKey: String = ""

    /// 当前选中润色 Provider 的 API Key 录入缓冲。
    var polishAPIKey: String = ""

    /// 是否已通过 ChatGPT OAuth 登录（钥匙串里有 token）。
    private(set) var isChatGPTLoggedIn: Bool = false

    /// OAuth 登录进行中（按钮置灰、显示进度）。
    private(set) var isLoggingIn: Bool = false

    /// STT 凭据操作（云端转写密钥保存）的提示文案，仅在 STT 分页展示，与润色分页互不串。
    private(set) var sttStatusMessage: String?

    /// 润色凭据操作（各 Provider 密钥保存、ChatGPT 登录/登出）的提示文案，仅在润色分页展示。
    private(set) var polishStatusMessage: String?

    /// 当前润色 Provider 对应的 API Key Keychain account；ChatGPT 走 OAuth 无 account。
    private var polishKeychainAccount: String? {
        Self.apiKeyAccount(for: providerKind)
    }

    /// Provider → API Key Keychain account 的映射（App 层私有；ChatGPT 用 OAuth，返回 nil）。
    static func apiKeyAccount(for kind: ProviderKind) -> String? {
        switch kind {
        case .openAI:    return KeychainStore.Account.openAIAPIKey
        case .deepSeek:  return KeychainStore.Account.deepSeekAPIKey
        case .anthropic: return KeychainStore.Account.anthropicAPIKey
        case .chatGPT:   return nil
        }
    }

    /// 当前 Provider 是否用 ChatGPT OAuth（而非 API Key）。
    var providerUsesOAuth: Bool { providerKind == .chatGPT }

    /// 从钥匙串重新加载各录入缓冲与登录状态。进入面板或切换 Provider 后调用。
    func reloadCredentials() {
        cloudSTTAPIKey = KeychainStore.get(account: KeychainStore.Account.openAIAPIKey) ?? ""
        if let account = polishKeychainAccount {
            polishAPIKey = KeychainStore.get(account: account) ?? ""
        } else {
            polishAPIKey = ""
        }
        isChatGPTLoggedIn = KeychainStore.loadChatGPTTokens() != nil
    }

    /// 切换润色 Provider 后：重载该 Provider 的 API Key 缓冲（清掉上一个 Provider 残留）。
    func providerDidChange() {
        if let account = polishKeychainAccount {
            polishAPIKey = KeychainStore.get(account: account) ?? ""
        } else {
            polishAPIKey = ""
        }
    }

    /// 保存云端 STT 的 API Key（写 OpenAI 的 account；空字符串视为不变更，避免误清空）。
    func saveCloudSTTAPIKey() {
        let trimmed = cloudSTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ok = KeychainStore.set(trimmed, account: KeychainStore.Account.openAIAPIKey)
        sttStatusMessage = ok
            ? String(localized: "stt.keySaved", defaultValue: "Cloud transcription key saved")
            : String(localized: "stt.keySaveFailed", defaultValue: "Failed to save cloud transcription key")
    }

    /// 保存当前润色 Provider 的 API Key。ChatGPT（OAuth）无 API Key，直接忽略。
    func savePolishAPIKey() {
        guard let account = polishKeychainAccount else { return }
        let trimmed = polishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ok = KeychainStore.set(trimmed, account: account)
        let name = providerKind.displayName
        polishStatusMessage = ok
            ? String(localized: "polish.keySaved \(name)")
            : String(localized: "polish.keySaveFailed \(name)")
    }

    // MARK: ChatGPT OAuth

    /// 触发 ChatGPT 登录（复用 App 层 ``CodexLoginService``）。
    func loginWithChatGPT() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        polishStatusMessage = String(localized: "polish.openingBrowser",
                                     defaultValue: "Opening browser to authorize ChatGPT…")
        CodexLoginService.shared.login { [weak self] result in
            guard let self else { return }
            self.isLoggingIn = false
            switch result {
            case .success:
                self.isChatGPTLoggedIn = true
                self.polishStatusMessage = String(localized: "polish.loginSucceeded",
                                                   defaultValue: "ChatGPT login succeeded")
            case .failure(let error):
                self.isChatGPTLoggedIn = KeychainStore.loadChatGPTTokens() != nil
                self.polishStatusMessage = String(localized: "polish.loginFailed \(String(describing: error))")
            }
        }
    }

    /// 退出 ChatGPT 登录（清钥匙串里的 token）。
    func logoutChatGPT() {
        let ok = KeychainStore.clearChatGPTTokens()
        isChatGPTLoggedIn = KeychainStore.loadChatGPTTokens() != nil
        polishStatusMessage = ok
            ? String(localized: "polish.loggedOut", defaultValue: "Signed out of ChatGPT")
            : String(localized: "polish.logoutFailed", defaultValue: "Sign-out failed")
    }

    // MARK: 权限

    /// 麦克风授权状态。
    private(set) var microphoneStatus: MicrophoneAuthorization = .notDetermined

    /// 辅助功能（Accessibility）是否已信任（全局热键与文本注入的前置条件）。
    private(set) var accessibilityTrusted: Bool = false

    /// 刷新两项权限状态（不弹窗）。进入「权限」分页或从系统设置返回时调用。
    func refreshPermissions() {
        microphoneStatus = MicrophonePermission.current
        // 复用 SayItCore 已有的辅助功能信任查询（HotkeyManager / AXTextInserter 同源）。
        accessibilityTrusted = HotkeyManager.isProcessTrusted
    }

    /// 请求麦克风权限：未决时弹系统对话框，否则只刷新状态。
    func requestMicrophone() async {
        if microphoneStatus == .notDetermined {
            microphoneStatus = await MicrophonePermission.requestStatus()
        } else {
            openMicrophoneSettings()
        }
    }

    /// 打开「系统设置 › 隐私与安全性 › 麦克风」。
    func openMicrophoneSettings() {
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// 打开「系统设置 › 隐私与安全性 › 辅助功能」。
    func openAccessibilitySettings() {
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
