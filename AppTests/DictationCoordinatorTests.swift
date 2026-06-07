import XCTest
@testable import SayIt
@testable import SayItCore

/// Unit test for `DictationCoordinator`'s orchestration logic: exercises the main branches with a Fake recorder/injector/transcriber.
///
/// The coordinator is driven by the hotkey event stream, and real events depend on NSEvent global monitoring, so here its `_test_*` entry points
/// directly drive the same private handlers and await the internal tasks, guaranteeing determinism. The HUD uses a separate instance of the real `RecordingPanelController`
/// (no frontmost focus touched, no side effects).
@MainActor
final class DictationCoordinatorTests: XCTestCase {

    /// Builds an isolated AppConfig (separate UserDefaults suite, avoiding polluting .standard).
    private func makeConfig(polishEnabled: Bool = false) -> AppConfig {
        let suite = "test.coordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let config = AppConfig(defaults: defaults)
        config.polishEnabled = polishEnabled
        return config
    }

    /// Assembles an all-Fake coordinator. accessibilityGate is always true to bypass the real authorization environment.
    /// modelReadiness defaults to always true: most tests use the injected Fake transcriber and should go straight to transcription without triggering the local model gate.
    /// transcribeTimeout defaults very short, to avoid any branch truly waiting out the full 90s.
    private func makeCoordinator(
        config: AppConfig,
        recorder: FakeAudioRecorder,
        injector: FakeTextInjector,
        panel: RecordingPanelController = RecordingPanelController(),
        dictionaryStore: DictionaryStore? = nil,
        modelReadiness: @escaping (String) -> Bool = { _ in true },
        transcribeTimeout: Duration = .seconds(5),
        transcriber: @escaping () throws -> any Transcriber
    ) -> DictationCoordinator {
        // By default inject an empty-dictionary store backed by a temp directory: an empty dictionary -> Layer 3 rewriting is identity (zero behavior change),
        // and it never touches the real user-dictionary file.
        let store = dictionaryStore ?? DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-dict-\(UUID().uuidString)"))
        return DictationCoordinator(
            config: config,
            recorder: recorder,
            panel: panel,
            injector: injector,
            dictionaryStore: store,
            transcriberFactory: transcriber,
            accessibilityGate: { true },
            modelReadiness: modelReadiness,
            transcribeTimeout: transcribeTimeout
        )
    }

    // MARK: - Normal loop: start -> stop -> inject

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

    // MARK: - User-dictionary Layer 3: empty dictionary = zero behavior change (injected text exactly equals transcript)

    /// Regression guard (Layer 3 wire-in): when the dictionary is empty, the deterministic rewriting between polish and injection must be identity --
    /// the injected text is byte-for-byte identical to the transcript, proving "zero behavior change" with an empty dictionary.
    func testEmptyDictionaryInjectsIdenticalTranscript() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        // Explicitly inject an empty-dictionary store backed by a temp directory (all() returns []).
        let emptyStore = DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-empty-\(UUID().uuidString)"))
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector, dictionaryStore: emptyStore
        ) {
            FakeTranscriber(text: "Call use effect here")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertEqual(injector.injectedTexts, ["Call use effect here"],
                       "with an empty dictionary the injected text should be exactly identical to the transcript (zero behavior change)")
    }

    // MARK: - Empty audio: no transcription, no injection

    func testEmptyAudioDoesNotInject() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [])  // nothing said
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

    // MARK: - Empty transcription: no injection

    func testEmptyTranscriptDoesNotInject() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "   \n  ")  // silence/unintelligible -> empty after trim
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "空转写不应注入")
    }

    // MARK: - Transcription failure: no injection

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

    // MARK: - Injection failure: the text is still attempted to be injected (left in the clipboard), no crash

    func testInjectionFailureStillAttemptsInjection() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .failedTextLeftInPasteboard(reason: "no focus"))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "要保住的话")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        // Never lose characters: even if injection fails, the text is sent into the injector (which internally leaves it in the clipboard).
        XCTAssertEqual(injector.injectedTexts, ["要保住的话"])
    }

    // MARK: - Recording start failure (microphone denied): no injection

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

    // MARK: - Extremely-short-press race: start closely followed by stop, stop not before start, no .notRecording thrown

    func testRapidStartStopAwaitsStartBeforeStop() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "极短按")
        }

        // Use the low-level handlers to simulate an extremely short press: start and stop are triggered one after another in the same synchronous block (start's recording Task has not finished yet).
        await coordinator._test_start()
        await coordinator._test_stop()

        // stop must execute after start: the recorder is started exactly once, stopped once, the text injected normally.
        let startCount = await recorder.startCount
        let stopCount = await recorder.stopCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(injector.injectedTexts, ["极短按"])
    }

    // MARK: - Polish failure falls back to the original and still injects (polishEnabled but no usable Provider)

    func testPolishFallbackStillInjectsRawTranscript() async {
        // Polish on but no credentials configured: makePolishProvider throws -> falls back to the original, still injects.
        let config = makeConfig(polishEnabled: true)
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "润色失败也要注入的原文")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        // Never lose characters: when polish Provider construction fails, fall back to injecting the original.
        XCTAssertEqual(injector.injectedTexts, ["润色失败也要注入的原文"])
    }

    // MARK: - Warm transcriber reuse: with config unchanged, reuse the same instance across multiple dictations (not rebuilding each time -> not reloading the model each time)

    /// Regression guard: the model-reload performance bug. With config unchanged, multiple dictations must reuse the same transcriber instance,
    /// and the factory is called only once -- otherwise each time would create a new `WhisperKitTranscriber(model:)` instance and lazily reload the ~1GB model (~10s).
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

    /// After a relevant STT config change (such as switching the local model), the transcriber should be rebuilt so the new model takes effect.
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

        // Switch the local model -> signature changes -> the next dictation should rebuild.
        config.localModel = "small"
        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertEqual(factoryCallCount, 2, "本地模型变更后应重建转写器")
    }

    // MARK: - item 2: writing back the same config value does not touch the state machine (not reset during a hold)

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
        // Sync the initial value.
        coordinator._test_applyHotkeyConfig()
        let keyBefore = manager.triggerKey
        let modeBefore = manager.mode

        // Call again with the same value: should not change (value-equality short-circuit).
        coordinator._test_applyHotkeyConfig()
        XCTAssertEqual(manager.triggerKey, keyBefore)
        XCTAssertEqual(manager.mode, modeBefore)
    }

    // MARK: - Local model not ready: no transcription, no injection, and not stuck "transcribing"

    /// Regression guard: in local mode with the model not downloaded, never call transcription (otherwise the underlying layer triggers a download, and the HUD stays permanently stuck
    /// "transcribing"). It should converge directly, not construct a transcriber, not inject, and no longer mark itself recording.
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
            modelReadiness: { _ in false }  // model not downloaded
        ) {
            transcriberMade = true
            return FakeTranscriber(text: "不应被转写")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertFalse(transcriberMade, "模型未就绪不应构造/调用转写器（避免触发下载与卡死）")
        XCTAssertTrue(injector.injectedTexts.isEmpty, "模型未就绪不应注入")
        XCTAssertFalse(coordinator._test_isRecording, "应收敛到非录音中")
        // Recording is stopped to release the device.
        let stopCount = await recorder.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    /// Cloud mode is not affected by the local model readiness gate: even with modelReadiness always false (the local model not downloaded),
    /// cloud transcription still proceeds normally and injects.
    func testCloudModeIgnoresLocalModelReadinessGate() async {
        let config = makeConfig()
        config.sttMode = .cloud
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in false }  // local model not downloaded, but cloud should not be blocked by it
        ) {
            FakeTranscriber(text: "云端转写结果")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertEqual(injector.injectedTexts, ["云端转写结果"], "云端模式应正常转写并注入")
    }

    // MARK: - Input device takes effect in real time: end-to-end dictation uses the persisted inputDeviceUID

    /// Regression guard: the microphone selected in the settings page must take effect immediately for the **next** dictation (no App restart needed).
    /// handleStart now reads config.inputDeviceUID and passes it to recorder.start(deviceUID:);
    /// the old bug called the no-arg start(), always recording the system default device, with the persisted choice never applied to the running pipeline.
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

    /// When no device is selected (nil), end-to-end dictation starts with the system default device (deviceUID passed nil).
    func testStartUsesSystemDefaultWhenNoDeviceSelected() async {
        let config = makeConfig()  // inputDeviceUID defaults to nil
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "你好")
        }

        await coordinator._test_start()

        let usedUID = await recorder.lastStartDeviceUID
        XCTAssertNil(usedUID, "未选设备时应传 nil（跟随系统默认）")
    }

    /// Real-time device-selection switching: change config.inputDeviceUID between two dictations, the second must use the new device
    /// (proving the running coordinator reads fresh on each press, no restart needed).
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

        // The settings page selects another device -> the next dictation should use the new device immediately.
        config.inputDeviceUID = "DeviceB"
        await coordinator._test_start()
        let secondUID = await recorder.lastStartDeviceUID
        XCTAssertEqual(secondUID, "DeviceB", "运行中的协调器应在下次听写现读最新设备选择")
    }

    // MARK: - Transcription hard timeout: never permanently stuck "transcribing"

    /// Regression guard: when transcription does not return in time (simulating the underlying layer stuck loading/downloading), the hard timeout intervenes, converges to idle, does not inject, does not hang.
    func testTranscribeTimeoutDoesNotHang() async {
        let config = makeConfig()
        config.sttMode = .cloud  // bypass the local readiness gate, ensuring entry into the transcription path that gets intercepted by the timeout
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            transcribeTimeout: .milliseconds(50)  // extremely short timeout
        ) {
            HangingTranscriber()  // never returns
        }

        // Without timeout protection, the step below would hang forever (test timeout failure).
        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "超时不应注入")
        XCTAssertFalse(coordinator._test_isRecording, "超时后应收敛到非录音中")
    }

    // MARK: - ESC cancel: mid-transcribe cancel injects nothing and returns to idle

    /// Regression guard (ESC-to-cancel): when a dictation is cancelled while the transcribe await is still in flight, the in-flight
    /// processing Task is cancelled, the pipeline early-returns at its `Task.isCancelled` / `CancellationError` guards, NOTHING is injected,
    /// the HUD/phase returns to idle, and the recorder is no longer marked recording.
    func testCancelMidTranscribeDoesNotInjectAndReturnsToIdle() async {
        let config = makeConfig()
        config.sttMode = .cloud  // bypass the local readiness gate so the pipeline reaches the transcribe await
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            transcribeTimeout: .seconds(30)  // long enough that the timeout never fires; the cancel is what aborts
        ) {
            HangingTranscriber()  // blocks (sleeps 3600s) until cancelled, so the cancel lands mid-transcribe
        }

        await coordinator._test_start()
        XCTAssertTrue(coordinator._test_isRecording)

        // Kick off the pipeline WITHOUT awaiting it, then yield so it reaches the (hanging) transcribe await.
        coordinator._test_handleStop()
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }

        // ESC: cancel mid-transcribe.
        coordinator._test_cancel()
        // Let the cancelled pipeline run its early-return + defer to completion.
        await coordinator._test_awaitProcessing()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "取消后绝不应注入任何文本")
        XCTAssertEqual(coordinator.phase, .idle, "取消后应复位到 idle")
        XCTAssertFalse(coordinator._test_isRecording, "取消后不应再标记为录音中")
    }

    // MARK: - ESC cancel when idle is a no-op

    /// Cancelling on a fresh (idle) coordinator does nothing: no injection, no recorder churn, phase stays idle.
    /// This proves the idle guard (ESC is ignored when no session is active).
    func testCancelWhenIdleIsNoOp() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "不应被调用")
        }

        coordinator._test_cancel()

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(injector.injectedTexts.isEmpty, "idle 时取消不应注入")
        let stopCount = await recorder.stopCount
        XCTAssertEqual(stopCount, 0, "idle 时取消不应触碰录音器")
    }

    // MARK: - Level forwarding: each session subscribes to the current session's level stream, forwarding to the HUD waveform

    /// Regression guard: the orchestration layer must subscribe to this session's level stream **after** `recorder.start()` succeeds,
    /// otherwise (the old bug: capturing the initial stream once at startup) the stream has long finished after the session is rebuilt, the forwarding loop spins idle,
    /// the HUD `level` stays at 0, and the listening-state dots go dead. This test simulates a tap delivering one level, asserting it is forwarded to the HUD.
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

        // Simulate a real tap delivering one normalized level on this session's stream (emitLevel is nonisolated, called synchronously).
        recorder.emitLevel(0.7)

        // The forwarding task asynchronously consumes the level and switches back to the main thread to refresh the HUD; poll-wait for it to arrive (avoiding dependence on a fixed sleep).
        let forwarded = await waitForLevel(panel, atLeast: 0.69)
        XCTAssertTrue(forwarded, "start 后投递的会话电平应被转发到 HUD（level≈0.7），而非恒为 0")
    }

    /// Poll-wait for the HUD's `currentLevel` to reach a threshold (the forwarding task is async, the main thread must be yielded multiple times).
    private func waitForLevel(_ panel: RecordingPanelController, atLeast threshold: Double) async -> Bool {
        for _ in 0..<200 {
            if panel.currentLevel >= threshold { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return panel.currentLevel >= threshold
    }
}

/// A never-returning transcriber: used to verify the hard timeout protection (its transcribe sleeps until cancelled).
private actor HangingTranscriber: Transcriber {
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?) async throws -> TranscriptionResult {
        // Sleep long enough (far beyond the test-injected timeout); the timeout branch cancels this task, and the CancellationError is swallowed by the timeout logic.
        try await Task.sleep(for: .seconds(3600))
        return TranscriptionResult(text: "never")
    }
}
