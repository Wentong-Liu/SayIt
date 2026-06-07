import AppKit
import SayItCore

/// 端到端听写编排器：把热键 → 录音 → 转写 → 润色 → 注入串成完整闭环。
///
/// 这是 App 层把各 `SayItCore` 模块「接线」起来的唯一处。所有具体能力都复用
/// 已有类型（不在此重复声明）：
/// - 触发：``HotkeyManager``（按 ``AppConfig`` 的触发键与交互模式产出 `.start` / `.stop`）。
/// - 录音：``AudioRecorder``（`actor`，麦克风 → 16kHz 单声道 `[Float]`）。
/// - 转写：本地 ``WhisperKitTranscriber`` 或云端 ``CloudTranscriber``（按 ``STTMode`` 选）。
/// - 润色：``PolishPipeline`` + App 层 ``ProviderFactory`` 构造的 ``LLMProvider``（失败自动回退原文）。
/// - 注入：``TextInjector``（剪贴板 ⌘V，注入到聚焦 App 光标处）。
/// - 反馈：``RecordingPanelController`` HUD（listening / transcribing / error / idle）。
///
/// 设计要点：
/// - 整个类型 `@MainActor`：UI（HUD、菜单栏状态）、热键监听、注入都须在主线程；转写 / 润色这类
///   耗时异步工作放进 `Task` 中 `await`，过程中 UI 切到 `transcribing`，不阻塞主线程。
/// - **绝不丢用户的话**：润色失败回退原文（``PolishPipeline`` 内建）；注入失败文本留在剪贴板并提示。
/// - **焦点漂移防护**：在 `.start` 时记录目标 App，注入前校验目标仍前台（漂移则仍注入到当前前台，
///   但通过 ``TextInjector`` 的剪贴板回退保证不丢字）。
/// - **空转写**：没说话 / 静音 → 不注入，HUD 给短暂提示后回到 idle。
@MainActor
final class DictationCoordinator {
    /// 进程级单例：由 ``AppDelegate`` 在启动时 `start()`。
    static let shared = DictationCoordinator()

    // MARK: 协作对象

    private let config: AppConfig
    private let hotkeyManager: HotkeyManager
    private let recorder: AudioRecording
    private let panel: RecordingPanelController
    private let injector: TextInjecting
    private let polishPipeline = PolishPipeline()

    /// 菜单栏 / 调用方可观察的高层状态（与 HUD 的细分态区分：这里只暴露 idle/listening/working）。
    enum Phase: Equatable, Sendable {
        case idle
        case listening
        case working
    }

    /// 当前高层状态变化回调（主线程），供菜单栏轻量反映 idle/listening。
    var onPhaseChange: ((Phase) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet {
            guard oldValue != phase else { return }
            onPhaseChange?(phase)
        }
    }

    // MARK: 运行期状态

    /// `.start` 时记录的注入目标 App，用于注入回填与焦点漂移校验。
    private var capturedTarget: InjectionTarget?

    /// 正在进行的「停止 → 转写 → 润色 → 注入」任务；防止重入。
    private var processingTask: Task<Void, Never>?

    /// 是否已启动监听（幂等保护）。
    private var isStarted = false

    /// 监听热键事件的长生命周期任务。
    private var eventLoopTask: Task<Void, Never>?

    /// 配置变更通知的观察者 token（block 形式注册，须用 token 移除）。
    private var configObserver: NSObjectProtocol?

    // MARK: 初始化

    /// - Parameters:
    ///   - config: 应用配置；默认 `.shared`。
    ///   - hotkeyManager: 热键管理器；默认按当前配置构造。
    ///   - recorder: 录音器；默认 ``AudioRecorder``。
    ///   - panel: HUD 控制器；默认共享实例。
    ///   - injector: 文本注入器；默认 ``TextInjector``。
    init(config: AppConfig = .shared,
         hotkeyManager: HotkeyManager? = nil,
         recorder: AudioRecording = AudioRecorder(),
         panel: RecordingPanelController = .shared,
         injector: TextInjecting = TextInjector()) {
        self.config = config
        self.recorder = recorder
        self.panel = panel
        self.injector = injector
        self.hotkeyManager = hotkeyManager
            ?? HotkeyManager(triggerKey: config.triggerKey,
                             mode: Self.hotkeyMode(for: config.interactionMode))
    }

    // MARK: 生命周期

    /// 启动监听并接入配置变更。重复调用幂等。
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // 配置变更（触发键 / 交互模式改动）后实时同步到热键管理器。
        configObserver = NotificationCenter.default.addObserver(
            forName: AppConfig.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHotkeyConfig() }
        }

        applyHotkeyConfig()
        startEventLoop()
        hotkeyManager.start()
        phase = .idle
    }

    /// 停止监听并清理（一般 App 退出前调用；非必需）。
    func stop() {
        guard isStarted else { return }
        isStarted = false
        hotkeyManager.stop()
        eventLoopTask?.cancel()
        eventLoopTask = nil
        processingTask?.cancel()
        processingTask = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        panel.hide()
        phase = .idle
    }

    /// 把当前配置（触发键 / 交互模式）同步给热键管理器。
    private func applyHotkeyConfig() {
        hotkeyManager.triggerKey = config.triggerKey
        hotkeyManager.mode = Self.hotkeyMode(for: config.interactionMode)
    }

    /// 消费热键事件流：`.start` 起录音，`.stop` 起转写流水线。
    private func startEventLoop() {
        let events = hotkeyManager.events
        eventLoopTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .start:
                    self.handleStart()
                case .stop:
                    self.handleStop()
                }
            }
        }
    }

    // MARK: 闭环 —— 开始

    /// `.start`：记录目标 App → 启动录音 → HUD 切 listening。
    private func handleStart() {
        // 上一轮还在处理（转写/润色/注入）时，忽略新的开始，避免交叠。
        guard processingTask == nil else { return }

        // 记录注入目标（注入回填 + 焦点漂移校验用）。
        capturedTarget = currentFrontmostTarget()

        panel.show(state: .listening)
        phase = .listening

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start()
            } catch {
                // 录音启动失败（多为麦克风未授权）：提示并收敛到 idle。
                self.failToIdle(message: Self.recordingFailureMessage(error))
            }
        }
    }

    // MARK: 闭环 —— 结束 → 转写 → 润色 → 注入

    /// `.stop`：停止录音拿样本，随后转写 → 润色 → 注入。
    private func handleStop() {
        // 没有进行中的录音或已在处理则忽略。
        guard processingTask == nil else { return }

        panel.update(state: .transcribing)
        phase = .working

        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.processingTask = nil }
            await self.runPipeline()
        }
    }

    /// 完整流水线：停止录音 → 转写 → （可选）润色 → 注入。在后台任务中执行，UI 调用切回主线程。
    private func runPipeline() async {
        // 1) 停止录音，取样本。
        let samples: [Float]
        do {
            samples = try await recorder.stop()
        } catch {
            failToIdle(message: "录音结束失败")
            return
        }

        // 空音频（没说话）：不转写、不注入，短暂提示后 idle。
        guard !samples.isEmpty else {
            emptyToIdle()
            return
        }

        // 2) 转写。
        let transcript: String
        do {
            let transcriber = try makeTranscriber()
            let result = try await transcriber.transcribe(
                samples,
                sampleRate: AudioFormat.sampleRate,
                language: requestedLanguage()
            )
            transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as STTError {
            failToIdle(message: Self.transcriptionFailureMessage(error))
            return
        } catch {
            failToIdle(message: "转写失败")
            return
        }

        // 空转写（静音 / 听不清）：不注入，短暂提示后 idle。
        guard !transcript.isEmpty else {
            emptyToIdle()
            return
        }

        // 3) 润色（开则走 LLM，失败/关闭自动回退原文，PolishPipeline 内建）。
        let finalText = await polishIfEnabled(transcript)

        // 4) 注入到目标 App 光标处。
        injectFinalText(finalText)
    }

    // MARK: 润色

    /// 按配置润色；构造 Provider 失败 / 润色失败都回退原文（绝不丢字）。
    private func polishIfEnabled(_ transcript: String) async -> String {
        guard config.polishEnabled else { return transcript }

        let provider: any LLMProvider
        do {
            provider = try await makePolishProvider()
        } catch {
            // 无凭据 / 构造失败：直接用原文（不阻断注入）。
            return transcript
        }

        let outcome = await polishPipeline.polish(
            transcript,
            context: polishContext(),
            style: config.polishStyle,
            provider: provider,
            polishEnabled: true
        )
        return outcome.text
    }

    /// 用当前（或注入目标）前台 App 信息构造润色上下文，帮助模型判断语域。
    private func polishContext() -> PolishContext {
        if let target = capturedTarget {
            return PolishContext(appName: target.localizedName, bundleId: target.bundleIdentifier)
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            return PolishContext(appName: app.localizedName, bundleId: app.bundleIdentifier)
        }
        return PolishContext()
    }

    /// 按 ``AppConfig/providerKind`` + 凭据构造润色用 ``LLMProvider``。
    /// 复用 App 层 ``ProviderFactory``，凭据 account 映射与设置页一致。
    private func makePolishProvider() async throws -> any LLMProvider {
        let model = config.model
        switch config.providerKind {
        case .openAI:
            return try await ProviderFactory.make(
                .openAICompatible(config: .openAI(model: model),
                                  keychainAccount: KeychainStore.Account.openAIAPIKey,
                                  sendsImages: false))
        case .deepSeek:
            return try await ProviderFactory.make(
                .openAICompatible(config: .deepSeek(model: model),
                                  keychainAccount: KeychainStore.Account.deepSeekAPIKey,
                                  sendsImages: false))
        case .anthropic:
            return try await ProviderFactory.make(
                .anthropic(config: .anthropic(model: model),
                           keychainAccount: KeychainStore.Account.anthropicAPIKey))
        case .chatGPT:
            return try await ProviderFactory.make(.codexOAuth(model: model))
        }
    }

    // MARK: 转写器构造

    /// 按 ``STTMode`` 选转写器。本地用 ``WhisperKitTranscriber``，云端用 ``CloudTranscriber``。
    private func makeTranscriber() throws -> any Transcriber {
        switch config.sttMode {
        case .local:
            return WhisperKitTranscriber(model: config.localModel)
        case .cloud:
            let key = (KeychainStore.get(account: KeychainStore.Account.openAIAPIKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw STTError.notReady }
            return CloudTranscriber(apiKey: key, model: config.cloudSTTModel)
        }
    }

    /// 配置语言映射到转写参数：`"auto"` / 空 → `nil`（让后端自动检测）。
    private func requestedLanguage() -> String? {
        let lang = config.language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lang.isEmpty, lang.lowercased() != "auto" else { return nil }
        return lang
    }

    // MARK: 注入

    /// 注入最终文本：焦点漂移时仍注入到当前前台（剪贴板回退保证不丢字），结果驱动 HUD。
    private func injectFinalText(_ text: String) {
        let drifted = focusDrifted()
        let result = injector.inject(text)

        switch result {
        case .success:
            // 焦点漂移仍成功（粘贴到了新前台）时不报错，但 HUD 直接收敛。
            panel.hide()
            phase = .idle
        case .failedTextLeftInPasteboard:
            // 文本已留剪贴板，提示用户手动粘贴。
            let hint = drifted ? "焦点已切换，文本已复制，请手动粘贴" : "已复制到剪贴板，请手动粘贴"
            showTransientError(hint)
        }
    }

    /// 注入目标是否已不再前台（焦点漂移）。无记录目标时视为未漂移。
    private func focusDrifted() -> Bool {
        guard let captured = capturedTarget,
              let current = currentFrontmostTarget() else {
            return false
        }
        return captured.processIdentifier != current.processIdentifier
    }

    // MARK: 状态收敛工具

    /// 取当前前台 App 快照。
    private func currentFrontmostTarget() -> InjectionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InjectionTarget(running: app)
    }

    /// 空音频 / 空转写：HUD 短暂提示后回到 idle。
    private func emptyToIdle() {
        showTransientError("没听清，请再说一次")
    }

    /// 失败收敛：HUD 短暂报错后回到 idle，并尽力停掉仍在跑的录音。
    private func failToIdle(message: String) {
        // 录音可能仍在进行（如启动后立即出错的边角场景），尽力停止以释放设备。
        Task { [recorder] in _ = try? await recorder.stop() }
        showTransientError(message)
    }

    /// 在 HUD 上短暂显示错误，随后自动隐藏并回到 idle。
    private func showTransientError(_ message: String) {
        phase = .idle
        panel.update(state: .error(message))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self else { return }
            // 期间若已开始新一轮（HUD 在 listening/transcribing）则不要打断。
            guard self.processingTask == nil, self.phase == .idle else { return }
            self.panel.hide()
        }
    }

    // MARK: 静态映射 / 文案

    /// ``InteractionMode`` → ``HotkeyMode``。
    private static func hotkeyMode(for mode: InteractionMode) -> HotkeyMode {
        switch mode {
        case .hold:   return .holdToTalk
        case .toggle: return .toggle
        }
    }

    /// 录音启动失败的用户文案。
    private static func recordingFailureMessage(_ error: Error) -> String {
        if let audioError = error as? AudioRecordingError,
           case .microphonePermissionDenied = audioError {
            return "需要麦克风权限"
        }
        return "无法开始录音"
    }

    /// 转写失败的用户文案。
    private static func transcriptionFailureMessage(_ error: STTError) -> String {
        switch error {
        case .notReady:
            return "转写未就绪，请检查模型/密钥"
        case .emptyAudio:
            return "没听清，请再说一次"
        case .unsupportedFormat:
            return "音频格式不受支持"
        case .transcriptionFailed:
            return "转写失败"
        @unknown default:
            return "转写失败"
        }
    }
}
