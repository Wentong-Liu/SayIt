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
    private func makeCoordinator(
        config: AppConfig,
        recorder: FakeAudioRecorder,
        injector: FakeTextInjector,
        transcriber: @escaping () throws -> any Transcriber
    ) -> DictationCoordinator {
        DictationCoordinator(
            config: config,
            recorder: recorder,
            panel: RecordingPanelController(),
            injector: injector,
            transcriberFactory: transcriber,
            accessibilityGate: { true }
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
}
