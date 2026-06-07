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
    /// 润色管线：注入失败日志回调，便于排查（绝不丢字，仅观测）。
    private let polishPipeline = PolishPipeline(logFailure: { reason in
        NSLog("[SayIt] 润色失败回退原文: %@", reason)
    })

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

    /// 正在进行的 `recorder.start()` 任务句柄。极短按重入竞态防护：`handleStop` 须先 `await`
    /// 它完成，确保 `stop()` 不会早于 `start()` 在 actor 上执行而触发 `.notRecording`。
    private var startTask: Task<Void, Never>?

    /// 录音是否已成功启动（由启动 Task 在 `recorder.start()` 成功后置位）。
    private var isRecording = false

    /// 转发录音电平到 HUD 的长生命周期任务（每轮录音期间消费 `recorder.levels`）。
    private var levelTask: Task<Void, Never>?

    /// 是否已启动监听（幂等保护）。
    private var isStarted = false

    /// 监听热键事件的长生命周期任务。
    private var eventLoopTask: Task<Void, Never>?

    /// 配置变更通知的观察者 token（block 形式注册，须用 token 移除）。
    private var configObserver: NSObjectProtocol?

    // MARK: 初始化

    /// 转写器工厂：按当前配置产出 ``Transcriber``。默认按 ``STTMode`` 选本地/云端实现；
    /// 测试时可注入返回 ``FakeTranscriber`` 的工厂，从而走通转写/空转写/转写失败等分支。
    /// `throws` 以保留「构造失败（如云端缺 key）」语义。
    private let transcriberFactory: () throws -> any Transcriber

    /// 辅助功能授权门禁覆盖：非 nil 时取代默认的 ``ensureAccessibilityOrGuide()``。
    /// 测试注入恒 true 以绕开真实授权环境。
    private let accessibilityGateOverride: (() -> Bool)?

    /// - Parameters:
    ///   - config: 应用配置；默认 `.shared`。
    ///   - hotkeyManager: 热键管理器；默认按当前配置构造。
    ///   - recorder: 录音器；默认 ``AudioRecorder``。
    ///   - panel: HUD 控制器；默认共享实例。
    ///   - injector: 文本注入器；默认 ``TextInjector``。
    ///   - transcriberFactory: 转写器工厂；默认按配置选本地/云端（见 ``makeConfiguredTranscriber(_:)``）。
    ///   - accessibilityGate: 辅助功能门禁；默认按需引导授权（见 ``ensureAccessibilityOrGuide()``）。
    init(config: AppConfig = .shared,
         hotkeyManager: HotkeyManager? = nil,
         recorder: AudioRecording = AudioRecorder(),
         panel: RecordingPanelController = .shared,
         injector: TextInjecting = TextInjector(),
         transcriberFactory: (() throws -> any Transcriber)? = nil,
         accessibilityGate: (() -> Bool)? = nil) {
        self.config = config
        self.recorder = recorder
        self.panel = panel
        self.injector = injector
        self.hotkeyManager = hotkeyManager
            ?? HotkeyManager(triggerKey: config.triggerKey,
                             mode: Self.hotkeyMode(for: config.interactionMode))
        // 默认工厂引用 config 的当前 STT 设置；测试可整体替换。
        let cfg = config
        self.transcriberFactory = transcriberFactory ?? { try Self.makeConfiguredTranscriber(cfg) }
        self.accessibilityGateOverride = accessibilityGate
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
        startLevelForwarding()
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
        levelTask?.cancel()
        levelTask = nil
        startTask?.cancel()
        startTask = nil
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
    ///
    /// 仅在值**确有变化**时回写：因为 `HotkeyManager.mode` 的 setter 会复位内部状态机，
    /// 若在 hold 听写过程中（按住未松）收到无关配置变更通知而无条件回写同值，会把状态机
    /// 打回起点、丢掉「正在按住」的事实，导致后续松开不产出 `.stop`。赋值前判等即可避免。
    private func applyHotkeyConfig() {
        let desiredKey = config.triggerKey
        if hotkeyManager.triggerKey != desiredKey {
            hotkeyManager.triggerKey = desiredKey
        }
        let desiredMode = Self.hotkeyMode(for: config.interactionMode)
        if hotkeyManager.mode != desiredMode {
            hotkeyManager.mode = desiredMode
        }
    }

    /// 把录音电平流转发到 HUD 波形。每个值在主线程刷新 `RecordingPanelController`。
    private func startLevelForwarding() {
        let levels = recorder.levels
        levelTask = Task { [weak self] in
            for await level in levels {
                guard let self else { return }
                self.panel.update(level: level)
            }
        }
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

    /// `.start`：（首次）校验辅助功能授权 → 记录目标 App → 启动录音 → HUD 切 listening。
    private func handleStart() {
        // 上一轮还在处理（转写/润色/注入）时，忽略新的开始，避免交叠。
        guard processingTask == nil else { return }
        // 上一次按下的录音启动还没收尾（极短按）时，忽略再次开始，交由那一次自然走完。
        guard startTask == nil else { return }

        // 按需引导辅助功能授权：首次按下听写键且未授权时弹系统对话框（不再在启动时打扰）。
        // 未授权时全局热键虽能建立但收不到事件——但若能走到这里说明这次已收到，故仅做提示性引导。
        guard (accessibilityGateOverride ?? ensureAccessibilityOrGuide)() else { return }

        // 记录注入目标（注入回填 + 焦点漂移校验用）。
        capturedTarget = currentFrontmostTarget()

        panel.show(state: .listening)
        phase = .listening

        startTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }
            do {
                try await self.recorder.start()
                self.isRecording = true
            } catch {
                // 录音启动失败（多为麦克风未授权）：提示并收敛到 idle。
                self.isRecording = false
                self.failToIdle(message: Self.recordingFailureMessage(error))
            }
        }
    }

    /// 校验辅助功能授权；未授权则弹系统对话框引导并给 HUD 轻提示，返回 false（本次不录音）。
    /// 已授权返回 true。
    private func ensureAccessibilityOrGuide() -> Bool {
        if AccessibilityAuthorization.isTrusted { return true }
        // 未授权：触发系统授权对话框（prompt），并在 HUD 给一句引导。
        AccessibilityAuthorization.ensureTrusted(prompting: true)
        showTransientError(String(localized: "hud.needAccessibility",
                                  defaultValue: "Accessibility permission required — enable it in System Settings"))
        return false
    }

    // MARK: 闭环 —— 结束 → 转写 → 润色 → 注入

    /// `.stop`：停止录音拿样本，随后转写 → 润色 → 注入。
    private func handleStop() {
        // 已在处理则忽略。
        guard processingTask == nil else { return }
        // 极短按竞态：可能 `.stop` 紧跟 `.start`，此刻录音启动 Task 也许还没跑完。
        // 先取走启动句柄，进入 pipeline 后 `await` 它完成，确保 stop 不早于 start 在 actor 执行。
        let pendingStart = startTask

        // 进入处理态：从识别阶段、进度 0.0 起步（Typeless 风格进度条 0...0.5 = 识别）。
        updateProcessing(0.0, .transcribing)
        phase = .working

        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.processingTask = nil }
            await self.runPipeline(awaiting: pendingStart)
        }
    }

    /// 完整流水线：停止录音 → 转写 → （可选）润色 → 注入。在后台任务中执行，UI 调用切回主线程。
    /// - Parameter pendingStart: 本轮录音的启动 Task（可能仍在进行）；先 `await` 它完成再 stop。
    private func runPipeline(awaiting pendingStart: Task<Void, Never>?) async {
        // 0) 等待录音启动收尾，避免 stop 早于 start 触发 `.notRecording`。
        await pendingStart?.value

        // 启动失败（如麦克风被拒）时 isRecording 仍为 false：启动路径已提示并收敛，这里直接退出。
        guard isRecording else {
            panel.hide()
            phase = .idle
            return
        }

        // 1) 停止录音，取样本。
        let samples: [Float]
        do {
            samples = try await recorder.stop()
            isRecording = false
        } catch {
            isRecording = false
            failToIdle(message: String(localized: "hud.stopRecordingFailed",
                                       defaultValue: "Failed to finish recording"))
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
            let transcriber = try transcriberFactory()
            // 语音识别恒自动检测语言（T24）：始终传 nil 让后端按语音判断，不再读 AppConfig.language。
            let result = try await transcriber.transcribe(
                samples,
                sampleRate: AudioFormat.sampleRate,
                language: nil
            )
            transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as STTError {
            failToIdle(message: Self.transcriptionFailureMessage(error))
            return
        } catch {
            failToIdle(message: String(localized: "hud.transcriptionFailed", defaultValue: "Transcription failed"))
            return
        }

        // 空转写（静音 / 听不清）：不注入，短暂提示后 idle。
        guard !transcript.isEmpty else {
            emptyToIdle()
            return
        }

        // 识别完成：到达进度条 50% 边界。开启润色则翻入润色阶段（0.5...1）；
        // 关闭润色则按需求识别完成即直接填满到 1.0（不展示润色阶段）。
        if config.polishEnabled {
            updateProcessing(0.5, .polishing)
        } else {
            updateProcessing(1.0, .transcribing)
        }

        // 3) 润色（开则走 LLM，失败/关闭自动回退原文，PolishPipeline 内建）。
        let polished = await polishIfEnabled(transcript)

        // 润色结束：填满进度条到 100%（关闭润色时上面已置 1.0，这里幂等）。
        if config.polishEnabled {
            updateProcessing(1.0, .polishing)
        }

        // 4) 注入到目标 App 光标处（润色失败时附带轻提示，但绝不丢字）。
        injectFinalText(polished.text, polishFailed: polished.failed)
    }

    // MARK: 润色

    /// 一次润色步骤的结果：最终文本 + 是否「失败回退」（用于注入后的可选提示）。
    private struct PolishStep {
        let text: String
        /// true 仅表示「调用了模型但失败/构造 Provider 失败」，跳过/关闭不计为失败。
        let failed: Bool
    }

    /// 按配置润色；构造 Provider 失败 / 润色失败都回退原文（绝不丢字）。
    private func polishIfEnabled(_ transcript: String) async -> PolishStep {
        guard config.polishEnabled else { return PolishStep(text: transcript, failed: false) }

        let provider: any LLMProvider
        do {
            provider = try await makePolishProvider()
        } catch {
            // 无凭据 / 构造失败：直接用原文（不阻断注入），计为失败以便可选提示。
            NSLog("[SayIt] 润色 Provider 构造失败，回退原文: %@", String(describing: error))
            return PolishStep(text: transcript, failed: true)
        }

        let outcome = await polishPipeline.polish(
            transcript,
            context: polishContext(),
            style: config.polishStyle,
            provider: provider,
            polishEnabled: true
        )
        // 仅 .failedFallback 计为失败；.polished / .skipped 不提示。
        let failed: Bool
        if case .failedFallback = outcome.resolution { failed = true } else { failed = false }
        return PolishStep(text: outcome.text, failed: failed)
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
    ///
    /// 云端路径**从 ``KeychainStore`` 取出 OpenAI API key 注入** ``CloudTranscriber``（其本身不读 Keychain，
    /// 保持可测）；key 缺失/空白则抛 `.notReady`，由调用方收敛到 HUD 提示。`static` 以便默认工厂闭包引用。
    private static func makeConfiguredTranscriber(_ config: AppConfig) throws -> any Transcriber {
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

    // MARK: 注入

    /// 注入最终文本：焦点漂移时仍注入到当前前台（剪贴板回退保证不丢字），结果驱动 HUD。
    /// - Parameters:
    ///   - text: 待注入文本。
    ///   - polishFailed: 润色是否失败回退（仅用于注入成功后的轻提示，不影响注入本身）。
    private func injectFinalText(_ text: String, polishFailed: Bool) {
        let drifted = focusDrifted()
        let result = injector.inject(text)

        switch result {
        case .success:
            if drifted {
                // 焦点漂移但仍粘贴成功：给一条短暂中性提示，告知粘到了当前窗口。
                showTransientInfo(String(localized: "hud.pastedToCurrentWindow",
                                         defaultValue: "Pasted to the current window"))
            } else if polishFailed {
                // 注入成功但润色失败回退了原文：轻提示（绝不丢字，仅告知）。
                showTransientInfo(String(localized: "hud.injectedPolishFailed",
                                         defaultValue: "Inserted (polish failed, used original text)"))
            } else {
                panel.hide()
                phase = .idle
            }
        case .failedTextLeftInPasteboard:
            // 文本已留剪贴板，提示用户手动粘贴。
            let hint = drifted
                ? String(localized: "hud.driftedCopiedPasteManually",
                         defaultValue: "Focus changed — text copied, please paste manually")
                : String(localized: "hud.copiedPasteManually",
                         defaultValue: "Copied to clipboard, please paste manually")
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

    /// 把处理进度（0...1）与当前阶段推到 HUD（Typeless 风格进度条）。
    /// 集中一处便于把贯穿流水线的进度更新写得紧凑、可读。
    private func updateProcessing(_ progress: Double, _ phase: RecordingState.ProcessingPhase) {
        panel.update(state: .processing(progress: progress, phase: phase))
    }

    /// 取当前前台 App 快照。
    private func currentFrontmostTarget() -> InjectionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InjectionTarget(running: app)
    }

    /// 空音频 / 空转写：HUD 短暂提示后回到 idle。
    private func emptyToIdle() {
        showTransientError(String(localized: "hud.didNotCatchThat", defaultValue: "Didn’t catch that, please try again"))
    }

    /// 失败收敛：HUD 短暂报错后回到 idle，并尽力停掉仍在跑的录音。
    private func failToIdle(message: String) {
        // 录音可能仍在进行（如启动后立即出错的边角场景），尽力停止以释放设备。
        isRecording = false
        Task { [recorder] in _ = try? await recorder.stop() }
        showTransientError(message)
    }

    /// 在 HUD 上短暂显示错误，随后自动隐藏并回到 idle。
    private func showTransientError(_ message: String) {
        showTransient(.error(message))
    }

    /// 在 HUD 上短暂显示中性提示（如「已粘贴到当前窗口」），随后自动隐藏并回到 idle。
    private func showTransientInfo(_ message: String) {
        showTransient(.info(message))
    }

    /// 在 HUD 上短暂显示某一瞬态（error / info），随后自动隐藏并回到 idle。
    private func showTransient(_ state: RecordingState) {
        phase = .idle
        panel.update(state: state)
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
        case .singleTap: return .singleTapToggle
        case .hold:      return .holdToTalk
        }
    }

    /// 录音启动失败的用户文案。
    private static func recordingFailureMessage(_ error: Error) -> String {
        if let audioError = error as? AudioRecordingError,
           case .microphonePermissionDenied = audioError {
            return String(localized: "hud.needMicrophone", defaultValue: "Microphone permission required")
        }
        return String(localized: "hud.cannotStartRecording", defaultValue: "Cannot start recording")
    }

    /// 转写失败的用户文案。
    private static func transcriptionFailureMessage(_ error: STTError) -> String {
        switch error {
        case .notReady:
            return String(localized: "hud.transcriberNotReady",
                          defaultValue: "Transcription not ready — check model/API key")
        case .emptyAudio:
            return String(localized: "hud.didNotCatchThat", defaultValue: "Didn’t catch that, please try again")
        case .unsupportedFormat:
            return String(localized: "hud.unsupportedAudioFormat", defaultValue: "Unsupported audio format")
        case .transcriptionFailed:
            return String(localized: "hud.transcriptionFailed", defaultValue: "Transcription failed")
        @unknown default:
            return String(localized: "hud.transcriptionFailed", defaultValue: "Transcription failed")
        }
    }

    // MARK: 测试支撑（test-only seams）
    //
    // 协调器经 HotkeyManager 的 AsyncStream 事件驱动，真实事件依赖 NSEvent 全局监听，无法在
    // 单测中合成。这里暴露 internal 入口直接驱动同一套私有 handler，并 await 内部任务以保证确定性。

    /// 直接触发一次「开始」并等待录音启动收尾（等价于收到 `.start` 热键事件）。
    func _test_start() async {
        handleStart()
        await startTask?.value
    }

    /// 直接触发一次「停止」并等待整条流水线（转写→润色→注入）跑完（等价于收到 `.stop`）。
    func _test_stop() async {
        handleStop()
        await processingTask?.value
    }

    /// 当前是否记录为正在录音（供测试断言竞态保护）。
    var _test_isRecording: Bool { isRecording }

    /// 直接调用配置同步（供测试断言 item 2 的判等回写行为）。
    func _test_applyHotkeyConfig() { applyHotkeyConfig() }

    /// 暴露热键管理器（供测试观察 triggerKey/mode）。
    var _test_hotkeyManager: HotkeyManager { hotkeyManager }
}
