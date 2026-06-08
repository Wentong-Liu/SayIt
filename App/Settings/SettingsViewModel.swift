import Observation
import os
import SwiftUI
import SayItCore

/// The view model for the settings interface: bridges the existing ``AppConfig`` (UserDefaults persistence) and ``KeychainStore`` (secrets)
/// into SwiftUI-bindable properties, and handles permission state queries and ChatGPT OAuth login orchestration.
///
/// Design points:
/// - **Does not redeclare any config type**: trigger key / interaction mode / STT mode / polish style / Provider all reuse
///   `SayItCore`'s single-source-of-truth enums. This type only does read/write bridging and UI orchestration.
/// - **Non-secret items** go to UserDefaults via `AppConfig`; **API Key / OAuth token** go to the keychain via `KeychainStore`.
/// - **Only reads/writes settings/credentials**, without end-to-end dictation orchestration (which belongs to T13).
@MainActor
@Observable
final class SettingsViewModel {
    /// The shared config (production uses `AppConfig.shared`). Not observable: each property's get/set forwards directly to it.
    @ObservationIgnored private let config: AppConfig

    /// The local model download/state manager. Its `state` is `@Observable`, the UI can observe its properties directly to drive refreshes.
    let modelManager: ModelManager

    /// Download/STT-related logging (same subsystem as `SayItCore`, with the category distinguished as settings).
    @ObservationIgnored private let log = Logger(subsystem: "com.liuwentong.SayIt", category: "settings")

    /// - Parameters:
    ///   - config: the injected config; defaults to `.shared`, unit tests/previews can pass an isolated instance.
    ///   - modelManager: the injected local model manager; defaults to creating a new one per the current `localModel`.
    init(config: AppConfig = .shared, modelManager: ModelManager? = nil) {
        self.config = config
        self.modelManager = modelManager ?? ModelManager(model: config.localModel)
        // Initialize every observable storage mirror to the current persisted value (write-through to config afterwards).
        // See each property's note below: using stored mirrors instead of computed forwards is what lets `@Observable`
        // track the write, invalidate the SwiftUI view instantly, and move the Picker's selection right away (no stale value).
        self.triggerKey = config.triggerKey
        self.interactionMode = config.interactionMode
        self.uiLanguage = config.uiLanguage
        self.sttMode = config.sttMode
        self.cloudSTTModel = config.cloudSTTModel
        self.polishEnabled = config.polishEnabled
        self.polishStyle = config.polishStyle
        self.soundCuesEnabled = config.soundCuesEnabled
        self.providerKind = config.providerKind
        self.model = config.model
        // Sync the secrets and permission state once on first entering the panel.
        reloadCredentials()
        refreshPermissions()
    }

    // MARK: General

    /// The modifier key that triggers dictation.
    ///
    /// This is an `@Observable`-tracked **stored** property (write-through to `config`), not a pure computed forward.
    /// The `@Observable` macro only injects Observation tracking (`access` in the getter / `withMutation` in the setter) for stored
    /// properties; if this read/wrote `config.triggerKey` instead (`AppConfig` is not `@Observable`), a Picker write would not
    /// invalidate the view and the selection would not move (it would keep showing the old value). Storing it here reflects instantly and persists.
    var triggerKey: TriggerKey {
        didSet {
            guard triggerKey != oldValue else { return }
            config.triggerKey = triggerKey
        }
    }

    /// The trigger interaction style (hold / tap to toggle). Stored mirror, same rationale as ``triggerKey``.
    var interactionMode: InteractionMode {
        didSet {
            guard interactionMode != oldValue else { return }
            config.interactionMode = interactionMode
        }
    }

    /// The UI display language (English / Simplified Chinese). On switch, immediately writes to disk and posts a notification, the root scene relocalizes the UI accordingly.
    /// Speech recognition is **no longer** driven by this (or the old `language`) field, and is always auto-detected (see ``DictationCoordinator``).
    /// Stored mirror, same rationale as ``triggerKey``.
    var uiLanguage: UILanguage {
        didSet {
            guard uiLanguage != oldValue else { return }
            config.uiLanguage = uiLanguage
        }
    }

    /// The UI language options (only English and Simplified Chinese); the display name is that language's endonym, not localized.
    let uiLanguageOptions: [UILanguage] = UILanguage.allCases

    /// Whether to play the start/stop chime cues on dictation. Stored mirror, same rationale as ``triggerKey``
    /// (write-through to `config` so the Toggle reflects live and persists; the coordinator reads `config` live each press).
    var soundCuesEnabled: Bool {
        didSet {
            guard soundCuesEnabled != oldValue else { return }
            config.soundCuesEnabled = soundCuesEnabled
        }
    }

    // MARK: STT

    /// Where speech transcription runs (local / cloud).
    ///
    /// This is an `@Observable`-tracked **stored** property (write-through to `config`), not a pure computed forward.
    /// Key correctness point: `STTSettingsView` binds the segmented control's `selection` and the conditional section below to this **same**
    /// observable source; if it were only a computed forward (reading/writing `config.sttMode`, while `AppConfig` is not `@Observable`),
    /// switching the segmented control would not invalidate Observation and the section below would not re-render instantly. Storing it here enables instant switching.
    var sttMode: STTMode {
        didSet {
            guard sttMode != oldValue else { return }
            config.sttMode = sttMode
        }
    }

    // MARK: Local model download
    //
    // The local model is fixed to ``AppConfig/localModel`` (always `"large-v3-turbo"`); there is no
    // user-selectable model and therefore no observable mirror. The download/state UI below reads the
    // model straight from `config` (always turbo), so it cannot drift from what the STT path loads.

    /// The download/cache state of the current local model (maintained in real time by ``ModelManager``, for the UI to observe).
    var localModelState: ModelManager.State { modelManager.state }

    /// On entering the settings page, refresh the download state per the current model's actual local cache (no network, no download).
    func refreshLocalModelState() {
        modelManager.setModel(config.localModel)
        modelManager.refreshState()
    }

    /// Triggers downloading the current local model. After the download finishes, if it failed, log the human-readable reason to os.Logger (.error).
    /// - Parameter force: when `true`, re-download even if already cached (for "re-download/retry").
    func downloadLocalModel(force: Bool = false) async {
        await modelManager.download(force: force)
        if case .failed(let reason) = modelManager.state {
            log.error("Local model download failed for \(self.config.localModel, privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// The human-readable reason for the current download failure (for the UI to display directly); nil when not in a failed state.
    var localModelFailureReason: String? {
        if case .failed(let reason) = modelManager.state { return reason }
        return nil
    }

    /// Cancels the in-progress local model download.
    func cancelLocalModelDownload() {
        modelManager.cancelDownload()
    }

    /// The cloud STT model identifier. Stored mirror, same rationale as ``triggerKey``.
    var cloudSTTModel: String {
        didSet {
            guard cloudSTTModel != oldValue else { return }
            config.cloudSTTModel = cloudSTTModel
        }
    }

    /// Cloud transcription model candidates: (id, display name). Currently mainly the OpenAI transcribe series.
    let cloudSTTModelOptions: [(id: String, label: String)] = [
        ("gpt-4o-mini-transcribe", "GPT-4o mini transcribe"),
        ("gpt-4o-transcribe", "GPT-4o transcribe"),
        ("whisper-1", "Whisper v1"),
    ]

    // MARK: Polish

    /// Whether to apply LLM polish to the transcription result. Stored mirror, same rationale as ``triggerKey``.
    var polishEnabled: Bool {
        didSet {
            guard polishEnabled != oldValue else { return }
            config.polishEnabled = polishEnabled
        }
    }

    /// The polish style. Stored mirror, same rationale as ``triggerKey``.
    var polishStyle: PolishStyle {
        didSet {
            guard polishStyle != oldValue else { return }
            config.polishStyle = polishStyle
        }
    }

    /// The Provider used for polish. After switching the Provider, clamps the model back to that Provider's default model, to avoid sending the wrong model id.
    /// Stored mirror, same rationale as ``triggerKey``; also refreshes the ``model`` mirror so the model Picker shows the new default instantly.
    var providerKind: ProviderKind {
        didSet {
            guard providerKind != oldValue else { return }
            config.providerKind = providerKind
            // After switching the Provider, clamp the model back to that Provider's default (avoid sending a model id that doesn't belong to it).
            // The ``model`` mirror's didSet writes this back to config and invalidates the model Picker's Observation so its selection updates instantly.
            model = providerKind.defaultModel
        }
    }

    /// The model id used for polish. Stored mirror, same rationale as ``triggerKey``.
    var model: String {
        didSet {
            guard model != oldValue else { return }
            config.model = model
        }
    }

    // MARK: Credentials (Keychain)

    /// The entry buffer for the API Key used by cloud STT (OpenAI transcribe). Written to the Keychain on blur/save.
    var cloudSTTAPIKey: String = ""

    /// The API Key entry buffer for the currently selected polish Provider.
    var polishAPIKey: String = ""

    /// Whether logged in via ChatGPT OAuth (a token exists in the keychain).
    private(set) var isChatGPTLoggedIn: Bool = false

    /// OAuth login in progress (the button is greyed out, showing progress).
    private(set) var isLoggingIn: Bool = false

    /// The hint copy for STT credential operations (saving the cloud transcription key), shown only on the STT page, not crossing with the polish page.
    private(set) var sttStatusMessage: String?

    /// The hint copy for polish credential operations (saving each Provider's key, ChatGPT login/logout), shown only on the polish page.
    private(set) var polishStatusMessage: String?

    /// The API Key Keychain account corresponding to the current polish Provider; ChatGPT goes through OAuth with no account.
    private var polishKeychainAccount: String? {
        Self.apiKeyAccount(for: providerKind)
    }

    /// The mapping of Provider -> API Key Keychain account (App-layer private; ChatGPT uses OAuth, returns nil).
    static func apiKeyAccount(for kind: ProviderKind) -> String? {
        switch kind {
        case .openAI:    return KeychainStore.Account.openAIAPIKey
        case .deepSeek:  return KeychainStore.Account.deepSeekAPIKey
        case .anthropic: return KeychainStore.Account.anthropicAPIKey
        case .chatGPT:   return nil
        }
    }

    /// Whether the current Provider uses ChatGPT OAuth (rather than an API Key).
    var providerUsesOAuth: Bool { providerKind == .chatGPT }

    /// Reloads each entry buffer and the login state from the keychain. Called on entering the panel or switching the Provider.
    func reloadCredentials() {
        cloudSTTAPIKey = KeychainStore.get(account: KeychainStore.Account.openAIAPIKey) ?? ""
        if let account = polishKeychainAccount {
            polishAPIKey = KeychainStore.get(account: account) ?? ""
        } else {
            polishAPIKey = ""
        }
        isChatGPTLoggedIn = KeychainStore.loadChatGPTTokens() != nil
    }

    /// After switching the polish Provider: reload that Provider's API Key buffer (clearing the previous Provider's leftover).
    func providerDidChange() {
        if let account = polishKeychainAccount {
            polishAPIKey = KeychainStore.get(account: account) ?? ""
        } else {
            polishAPIKey = ""
        }
    }

    /// Saves the cloud STT API Key (writes OpenAI's account; an empty string is treated as no change, to avoid accidental clearing).
    func saveCloudSTTAPIKey() {
        let trimmed = cloudSTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ok = KeychainStore.set(trimmed, account: KeychainStore.Account.openAIAPIKey)
        if ok {
            sttStatusMessage = uiLanguageLocalized("stt.keySaved", defaultValue: "Cloud transcription key saved")
            // Posting lets the coordinator refresh its cached cloud key, so a same-model key-only re-save takes effect next dictation.
            config.notifyExternalChange()
        } else {
            sttStatusMessage = uiLanguageLocalized("stt.keySaveFailed", defaultValue: "Failed to save cloud transcription key")
        }
    }

    /// Saves the current polish Provider's API Key. ChatGPT (OAuth) has no API Key, ignored directly.
    func savePolishAPIKey() {
        guard let account = polishKeychainAccount else { return }
        let trimmed = polishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ok = KeychainStore.set(trimmed, account: account)
        let name = providerKind.displayName
        polishStatusMessage = ok
            ? uiLanguageLocalized(format: "polish.keySaved %@", defaultValue: "%@ key saved", name)
            : uiLanguageLocalized(format: "polish.keySaveFailed %@", defaultValue: "Failed to save %@ key", name)
    }

    // MARK: ChatGPT OAuth

    /// Triggers ChatGPT login (reuses the App-layer ``CodexLoginService``).
    func loginWithChatGPT() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        polishStatusMessage = uiLanguageLocalized("polish.openingBrowser",
                                                  defaultValue: "Opening browser to authorize ChatGPT…")
        CodexLoginService.shared.login { [weak self] result in
            guard let self else { return }
            self.isLoggingIn = false
            switch result {
            case .success:
                self.isChatGPTLoggedIn = true
                self.polishStatusMessage = uiLanguageLocalized("polish.loginSucceeded",
                                                               defaultValue: "ChatGPT login succeeded")
            case .failure(let error):
                self.isChatGPTLoggedIn = KeychainStore.loadChatGPTTokens() != nil
                self.polishStatusMessage = uiLanguageLocalized(format: "polish.loginFailed %@",
                                                               defaultValue: "ChatGPT login failed: %@",
                                                               String(describing: error))
            }
        }
    }

    /// Logs out of ChatGPT login (clears the token in the keychain).
    func logoutChatGPT() {
        let ok = KeychainStore.clearChatGPTTokens()
        isChatGPTLoggedIn = KeychainStore.loadChatGPTTokens() != nil
        polishStatusMessage = ok
            ? uiLanguageLocalized("polish.loggedOut", defaultValue: "Signed out of ChatGPT")
            : uiLanguageLocalized("polish.logoutFailed", defaultValue: "Sign-out failed")
    }

    // MARK: Permissions

    /// The microphone authorization status.
    private(set) var microphoneStatus: MicrophoneAuthorization = .notDetermined

    /// Whether Accessibility is trusted (a prerequisite for global hotkeys and text injection).
    private(set) var accessibilityTrusted: Bool = false

    /// Refreshes the two permission states (no prompt). Called on entering the "Permissions" page or returning from System Settings.
    func refreshPermissions() {
        microphoneStatus = MicrophonePermission.current
        // Reuse SayItCore's existing accessibility trust query (same source as HotkeyManager / AXTextInserter).
        accessibilityTrusted = HotkeyManager.isProcessTrusted
    }

    /// Requests microphone permission: pops the system dialog when undetermined, otherwise just refreshes the state.
    func requestMicrophone() async {
        if microphoneStatus == .notDetermined {
            microphoneStatus = await MicrophonePermission.requestStatus()
        } else {
            openMicrophoneSettings()
        }
    }

    /// Opens System Settings > Privacy & Security > Microphone.
    func openMicrophoneSettings() {
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Opens System Settings > Privacy & Security > Accessibility.
    func openAccessibilitySettings() {
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
