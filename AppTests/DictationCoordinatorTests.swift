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
        modelReadiness: @escaping (String) -> Bool = { _ in true },
        transcribeTimeout: Duration = .seconds(5),
        transcriber: @escaping () throws -> any Transcriber
    ) -> DictationCoordinator {
        DictationCoordinator(
            config: config,
            recorder: recorder,
            panel: RecordingPanelController(),
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
}

/// 永不返回的转写器：用于验证硬超时保护（其 transcribe 会一直睡到被取消）。
private actor HangingTranscriber: Transcriber {
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?) async throws -> TranscriptionResult {
        // 睡足够久（远超测试注入的超时）；超时分支会取消本任务，CancellationError 由超时逻辑吞掉。
        try await Task.sleep(for: .seconds(3600))
        return TranscriptionResult(text: "never")
    }
}
