import XCTest
@testable import SayIt
@testable import SayItCore

/// `DictationCoordinator` 的编排逻辑单测：用 Fake 录音器/注入器/转写器走通主要分支。
///
/// 协调器经热键事件流驱动，真实事件依赖 NSEvent 全局监听，故这里用其 `_test_*` 入口
/// 直接驱动同一套私有 handler 并等待内部任务，保证确定性。HUD 用真实 `RecordingPanelController`
/// 的独立实例（不触前台焦点、无副作用）。
@MainActor
final class DictationCoordinatorTests: XCTestCase {

    /// 造一份隔离的 AppConfig（独立 UserDefaults suite，避免污染 .standard）。
    private func makeConfig(polishEnabled: Bool = false) -> AppConfig {
        let suite = "test.coordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let config = AppConfig(defaults: defaults)
        config.polishEnabled = polishEnabled
        return config
    }

    /// 组装一个全 Fake 的协调器。accessibilityGate 恒 true 以绕开真实授权环境。
    /// modelReadiness 默认恒 true：多数测试用注入的 Fake 转写器，应直接走转写而不触发本地模型门禁。
    /// transcribeTimeout 默认很短，避免任何分支真的等满 90s。
    private func makeCoordinator(
        config: AppConfig,
        recorder: FakeAudioRecorder,
        injector: FakeTextInjector,
        panel: RecordingPanelController = RecordingPanelController(),
        modelReadiness: @escaping (String) -> Bool = { _ in true },
        transcribeTimeout: Duration = .seconds(5),
        transcriber: @escaping () throws -> any Transcriber
    ) -> DictationCoordinator {
        DictationCoordinator(
            config: config,
            recorder: recorder,
            panel: panel,
            injector: injector,
            transcriberFactory: transcriber,
            accessibilityGate: { true },
            modelReadiness: modelReadiness,
            transcribeTimeout: transcribeTimeout
        )
    }

    // MARK: - 正常闭环：start → stop → inject

    func testHappyPathInjectsTranscribedText() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "你好世界")
        }

        await coordinator._test_start()
        XCTAssertTrue(coordinator._test_isRecording, "start 后应标记为录音中")
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 1)

        await coordinator._test_stop()

        XCTAssertEqual(injector.injectedTexts, ["你好世界"], "应注入转写文本")
        XCTAssertFalse(coordinator._test_isRecording, "stop 后应清录音标记")
        let stopCount = await recorder.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    // MARK: - 空音频：不转写、不注入

    func testEmptyAudioDoesNotInject() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [])  // 没说话
        let injector = FakeTextInjector()
        var transcriberMade = false
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            transcriberMade = true
            return FakeTranscriber(text: "不应被调用")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "空音频不应注入")
        XCTAssertFalse(transcriberMade, "空音频不应构造转写器")
    }

    // MARK: - 空转写：不注入

    func testEmptyTranscriptDoesNotInject() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "   \n  ")  // 静音/听不清 → trim 后为空
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "空转写不应注入")
    }

    // MARK: - 转写失败：不注入

    func testTranscriptionFailureDoesNotInject() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(error: .transcriptionFailed(reason: "boom"))
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "转写失败不应注入")
        XCTAssertFalse(coordinator._test_isRecording)
    }

    // MARK: - 注入失败：文本仍被尝试注入（留剪贴板），不崩

    func testInjectionFailureStillAttemptsInjection() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .failedTextLeftInPasteboard(reason: "no focus"))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "要保住的话")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        // 绝不丢字：即便注入失败，文本也被送进注入器（其内部会留剪贴板）。
        XCTAssertEqual(injector.injectedTexts, ["要保住的话"])
    }

    // MARK: - 录音启动失败（麦克风被拒）：不注入

    func testRecordingStartFailureDoesNotInject() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1], startBehavior: .throwsDenied)
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "不应被注入")
        }

        await coordinator._test_start()
        XCTAssertFalse(coordinator._test_isRecording, "启动失败不应标记录音中")

        await coordinator._test_stop()
        XCTAssertTrue(injector.injectedTexts.isEmpty, "录音没起来不应注入")
    }

    // MARK: - 极短按竞态：start 紧跟 stop，stop 不早于 start，不抛 .notRecording

    func testRapidStartStopAwaitsStartBeforeStop() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "极短按")
        }

        // 用底层 handler 模拟极短按：start 与 stop 在同一同步段先后触发（start 的录音 Task 尚未完成）。
        await coordinator._test_start()
        await coordinator._test_stop()

        // stop 必须在 start 之后执行：录音器恰好被 start 一次、stop 一次，文本正常注入。
        let startCount = await recorder.startCount
        let stopCount = await recorder.stopCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(injector.injectedTexts, ["极短按"])
    }

    // MARK: - 润色失败回退原文仍注入（polishEnabled 但无可用 Provider）

    func testPolishFallbackStillInjectsRawTranscript() async {
        // 打开润色但不配置任何凭据：makePolishProvider 会抛错 → 回退原文，仍注入。
        let config = makeConfig(polishEnabled: true)
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "润色失败也要注入的原文")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        // 绝不丢字：润色 Provider 构造失败时回退原文注入。
        XCTAssertEqual(injector.injectedTexts, ["润色失败也要注入的原文"])
    }

    // MARK: - 暖转写器复用：配置不变时跨多次听写复用同一实例（不每次重建 → 不每次重载模型）

    /// 回归守卫：模型重载性能 bug。配置不变时，多次听写必须复用同一个转写器实例，
    /// 工厂只被调用一次——否则每次都会 `WhisperKitTranscriber(model:)` 新实例并惰性重载 ~1GB 模型（~10s）。
    func testTranscriberReusedAcrossDictationsWhenConfigUnchanged() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        var factoryCallCount = 0
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            factoryCallCount += 1
            return FakeTranscriber(text: "复用")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        await coordinator._test_start()
        await coordinator._test_stop()
        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertEqual(factoryCallCount, 1, "配置不变时转写器应复用，工厂只构造一次（模型保持暖态）")
        XCTAssertEqual(injector.injectedTexts, ["复用", "复用", "复用"], "三次听写都应正常注入")
    }

    /// 相关 STT 配置变更（如本地模型切换）后应重建转写器，使新模型生效。
    func testTranscriberRebuiltWhenLocalModelChanges() async {
        let config = makeConfig()
        config.sttMode = .local
        config.localModel = "base"
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        var factoryCallCount = 0
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            factoryCallCount += 1
            return FakeTranscriber(text: "model")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertEqual(factoryCallCount, 1)

        // 切换本地模型 → 签名变化 → 下次听写应重建。
        config.localModel = "small"
        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertEqual(factoryCallCount, 2, "本地模型变更后应重建转写器")
    }

    // MARK: - item 2：配置同值回写不动状态机（hold 中不被复位）

    func testApplyHotkeyConfigSkipsRewriteWhenUnchanged() async {
        let config = makeConfig()
        config.triggerKey = .rightCommand
        config.interactionMode = .hold
        let recorder = FakeAudioRecorder()
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "x")
        }

        let manager = coordinator._test_hotkeyManager
        // 同步初始值。
        coordinator._test_applyHotkeyConfig()
        let keyBefore = manager.triggerKey
        let modeBefore = manager.mode

        // 再次以同值调用：不应改变（值判等短路）。
        coordinator._test_applyHotkeyConfig()
        XCTAssertEqual(manager.triggerKey, keyBefore)
        XCTAssertEqual(manager.mode, modeBefore)
    }

    // MARK: - 本地模型未就绪：不转写、不注入，且不卡在「识别中」

    /// 回归守卫：本地模式且模型未下载时，绝不调用转写（否则底层会触发下载、HUD 永久卡在
    /// 「识别中」）。应直接收敛，不构造转写器、不注入、不再标记录音中。
    func testLocalModelNotReadyDoesNotTranscribeOrHang() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        var transcriberMade = false
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in false }  // 模型未下载
        ) {
            transcriberMade = true
            return FakeTranscriber(text: "不应被转写")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertFalse(transcriberMade, "模型未就绪不应构造/调用转写器（避免触发下载与卡死）")
        XCTAssertTrue(injector.injectedTexts.isEmpty, "模型未就绪不应注入")
        XCTAssertFalse(coordinator._test_isRecording, "应收敛到非录音中")
        // 录音被停掉以释放设备。
        let stopCount = await recorder.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    /// 云端模式不受本地模型就绪门禁影响：即便 modelReadiness 恒 false（本地模型没下），
    /// 云端转写仍正常进行并注入。
    func testCloudModeIgnoresLocalModelReadinessGate() async {
        let config = makeConfig()
        config.sttMode = .cloud
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in false }  // 本地模型未下载，但云端不该被它挡住
        ) {
            FakeTranscriber(text: "云端转写结果")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertEqual(injector.injectedTexts, ["云端转写结果"], "云端模式应正常转写并注入")
    }

    // MARK: - 输入设备实时生效：端到端听写用持久化的 inputDeviceUID

    /// 回归守卫：设置页选定的麦克风必须对**下一次**听写立即生效（无需重启 App）。
    /// handleStart 现读 config.inputDeviceUID 并传给 recorder.start(deviceUID:)；
    /// 旧 bug 是调用无参 start()，永远录系统默认设备，持久化的选择从不应用到运行中的流水线。
    func testStartUsesPersistedInputDevice() async {
        let config = makeConfig()
        config.inputDeviceUID = "DeviceXYZ"
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "你好")
        }

        await coordinator._test_start()

        let usedUID = await recorder.lastStartDeviceUID
        XCTAssertEqual(usedUID, "DeviceXYZ", "端到端听写应使用持久化选定的输入设备")
    }

    /// 未选设备（nil）时，端到端听写以系统默认设备开始（deviceUID 传 nil）。
    func testStartUsesSystemDefaultWhenNoDeviceSelected() async {
        let config = makeConfig()  // inputDeviceUID 默认为 nil
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "你好")
        }

        await coordinator._test_start()

        let usedUID = await recorder.lastStartDeviceUID
        XCTAssertNil(usedUID, "未选设备时应传 nil（跟随系统默认）")
    }

    /// 设备选择实时切换：两次听写之间改 config.inputDeviceUID，第二次须用新设备
    /// （证明运行中的协调器每次按下都现读，无需重启）。
    func testStartPicksUpDeviceChangeBetweenDictations() async {
        let config = makeConfig()
        config.inputDeviceUID = "DeviceA"
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "x")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        let firstUID = await recorder.lastStartDeviceUID
        XCTAssertEqual(firstUID, "DeviceA")

        // 设置页改选另一台设备 → 下一次听写应立即用新设备。
        config.inputDeviceUID = "DeviceB"
        await coordinator._test_start()
        let secondUID = await recorder.lastStartDeviceUID
        XCTAssertEqual(secondUID, "DeviceB", "运行中的协调器应在下次听写现读最新设备选择")
    }

    // MARK: - 转写硬超时：绝不永久卡在「识别中」

    /// 回归守卫：转写迟迟不返回（模拟底层卡在加载/下载）时，硬超时介入、收敛到 idle，不注入、不卡死。
    func testTranscribeTimeoutDoesNotHang() async {
        let config = makeConfig()
        config.sttMode = .cloud  // 绕过本地就绪门禁，确保进入会被超时拦截的转写路径
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            transcribeTimeout: .milliseconds(50)  // 极短超时
        ) {
            HangingTranscriber()  // 永不返回
        }

        // 若无超时保护，下面这步会永久挂起（测试超时失败）。
        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "超时不应注入")
        XCTAssertFalse(coordinator._test_isRecording, "超时后应收敛到非录音中")
    }

    // MARK: - 电平转发：每会话订阅当前会话的电平流，转发到 HUD 波形

    /// 回归守卫：编排层必须在 `recorder.start()` **成功之后** 订阅本会话的电平流，
    /// 否则（旧 bug：启动时一次性捕获初始流）会话重建后流早已 finish，转发循环空转、
    /// HUD `level` 恒为 0、聆听态圆点僵死。本测试模拟 tap 投递一个电平，断言它被转发到 HUD。
    func testLevelForwardedToPanelAfterStart() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let panel = RecordingPanelController()
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector, panel: panel
        ) {
            FakeTranscriber(text: "x")
        }

        await coordinator._test_start()
        XCTAssertTrue(coordinator._test_isRecording, "start 后应在录音中")

        // 模拟真实 tap 在本会话的流上投递一个归一化电平（emitLevel 为 nonisolated，同步调用）。
        recorder.emitLevel(0.7)

        // 转发任务异步消费电平并切回主线程刷新 HUD；轮询等待其抵达（避免依赖固定睡眠）。
        let forwarded = await waitForLevel(panel, atLeast: 0.69)
        XCTAssertTrue(forwarded, "start 后投递的会话电平应被转发到 HUD（level≈0.7），而非恒为 0")
    }

    /// 轮询等待 HUD 的 `currentLevel` 达到阈值（转发任务异步，需让出主线程多次）。
    private func waitForLevel(_ panel: RecordingPanelController, atLeast threshold: Double) async -> Bool {
        for _ in 0..<200 {
            if panel.currentLevel >= threshold { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return panel.currentLevel >= threshold
    }
}

/// 永不返回的转写器：用于验证硬超时保护（其 transcribe 会一直睡到被取消）。
private actor HangingTranscriber: Transcriber {
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?) async throws -> TranscriptionResult {
        // 睡足够久（远超测试注入的超时）；超时分支会取消本任务，CancellationError 由超时逻辑吞掉。
        try await Task.sleep(for: .seconds(3600))
        return TranscriptionResult(text: "never")
    }
}
