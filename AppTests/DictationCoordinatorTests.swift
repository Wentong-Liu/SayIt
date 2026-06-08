import XCTest
@testable import SayIt
@testable import SayItCore

/// Unit test for `DictationCoordinator`'s orchestration logic: exercises the main branches with a Fake recorder/injector/transcriber.
///
/// The coordinator is driven by the hotkey event stream, and real events depend on NSEvent global monitoring, so here its `_test_*` entry points
/// directly drive the same private handlers and await the internal tasks, guaranteeing determinism. The suite is hermetically silent and windowless:
/// the HUD/suggestion panels are constructed `headless: true` (model/state updated, but no NSPanel ordered on screen) and a no-op `SilentSoundCues`
/// is injected (no audible chime), so running the tests touches no frontmost focus, opens no window, and plays no sound.
@MainActor
final class DictationCoordinatorTests: XCTestCase {

    /// Builds an isolated AppConfig (separate UserDefaults suite, avoiding polluting .standard).
    private func makeConfig(polishEnabled: Bool = false) -> AppConfig {
        let suite = "test.coordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let config = AppConfig(defaults: defaults)
        config.polishEnabled = polishEnabled
        config.soundCuesEnabled = false   // belt-and-suspenders: silence the chime gate in addition to the no-op player
        return config
    }

    /// Assembles an all-Fake coordinator. accessibilityGate is always true to bypass the real authorization environment.
    /// modelReadiness defaults to always true: most tests use the injected Fake transcriber and should go straight to transcription without triggering the local model gate.
    /// transcribeTimeout defaults very short, to avoid any branch truly waiting out the full 90s.
    private func makeCoordinator(
        config: AppConfig,
        recorder: FakeAudioRecorder,
        injector: FakeTextInjector,
        panel: RecordingPanelController = RecordingPanelController(headless: true),
        dictionaryStore: DictionaryStore? = nil,
        modelReadiness: @escaping (String) -> Bool = { _ in true },
        transcribeTimeout: Duration = .seconds(5),
        cloudKeyReader: (@Sendable () -> String)? = nil,
        axReader: FocusedTextReading? = nil,
        suggestionPanel: SuggestionPanelController? = nil,
        learnFreshness: Duration = .seconds(8),
        learnDebounce: Duration = .milliseconds(1),
        transcriber: @escaping () throws -> any Transcriber
    ) -> DictationCoordinator {
        // By default inject an empty-dictionary store backed by a temp directory: an empty dictionary -> Layer 3 rewriting is identity (zero behavior change),
        // and it never touches the real user-dictionary file.
        let store = dictionaryStore ?? DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-dict-\(UUID().uuidString)"))
        // Default learn-from-edits reader returns nil (never arms) so tests that don't exercise the feature are unaffected;
        // a fresh suggestion panel avoids touching the shared singleton. The debounce defaults to ~1ms for fast tests.
        return DictationCoordinator(
            config: config,
            recorder: recorder,
            panel: panel,
            injector: injector,
            dictionaryStore: store,
            transcriberFactory: transcriber,
            accessibilityGate: { true },
            modelReadiness: modelReadiness,
            transcribeTimeout: transcribeTimeout,
            soundCues: SilentSoundCues(),
            cloudKeyReader: cloudKeyReader,
            axReader: axReader ?? FakeFocusedTextReader(single: nil),
            suggestionPanel: suggestionPanel ?? SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true),
            learnFreshness: learnFreshness,
            learnDebounce: learnDebounce
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

    // MARK: - User-dictionary Layer 1: transcribe-call biasing wire-in

    /// A non-empty dictionary must thread the enabled entries' canonical terms into the transcribe call's biasing options
    /// (Layer 1 STT recall boost). Disabled entries are excluded.
    func testNonEmptyDictionaryThreadsCanonicalTermsIntoTranscribe() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let store = DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-bias-\(UUID().uuidString)"))
        await store.add(DictionaryEntry(canonical: "SwiftUI", usageCount: 1))
        await store.add(DictionaryEntry(canonical: "WhisperKit", usageCount: 5))
        await store.add(DictionaryEntry(canonical: "disabled-term", enabled: false))

        let transcriber = FakeTranscriber(text: "result")
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector, dictionaryStore: store
        ) {
            transcriber
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        let calls = await transcriber.calls
        XCTAssertEqual(calls.count, 1)
        // Only enabled entries' canonicals are threaded through (disabled entry excluded), AND now in usageCount-ascending
        // order (most-used LAST) — the documented ordering is active end-to-end via GlossaryPrompt.orderedCanonicals.
        // SwiftUI(usage 1) before WhisperKit(usage 5); disabled-term excluded.
        XCTAssertEqual(calls.first?.biasTerms, ["SwiftUI", "WhisperKit"],
                       "非空词典应把启用条目按 usageCount 升序（最常用在尾部）透传给转写调用，禁用条目排除")
    }

    /// A2 ordering active: higher-usage terms must sit LAST in the biasTerms array reaching the transcribe call,
    /// so the WhisperKit token-cap suffix keeps the highest-usage terms (the documented ordering now runs).
    func testBiasTermsAreUsageCountAscendingAtTranscribeCall() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let store = DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-order-\(UUID().uuidString)"))
        // Add out of usage order to prove the coordinator (not insertion order) decides the layout.
        await store.add(DictionaryEntry(canonical: "common", usageCount: 99))
        await store.add(DictionaryEntry(canonical: "rare", usageCount: 1))
        await store.add(DictionaryEntry(canonical: "mid", usageCount: 50))

        let transcriber = FakeTranscriber(text: "x")
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector, dictionaryStore: store
        ) {
            transcriber
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        let calls = await transcriber.calls
        XCTAssertEqual(calls.first?.biasTerms, ["rare", "mid", "common"],
                       "偏置词应按 usageCount 升序到达转写调用（最常用在尾部，使 token 上限保留高频词）")
    }

    /// An empty dictionary must pass empty bias terms to the transcribe call (no biasing -> byte-identical to today).
    func testEmptyDictionaryPassesEmptyBiasTerms() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let emptyStore = DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-bias-empty-\(UUID().uuidString)"))

        let transcriber = FakeTranscriber(text: "result")
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector, dictionaryStore: emptyStore
        ) {
            transcriber
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        let calls = await transcriber.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.biasTerms, [], "空词典应传空偏置词（不构造任何 prompt）")
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

    // MARK: - ESC cancel then immediate restart: a fresh session must begin reliably

    /// Regression guard (cancel-then-restart race): after ESC-cancel fires the recorder stop in flight, pressing the hotkey again
    /// IMMEDIATELY must start a fresh recording session reliably. Previously `cancel()` ran the recorder stop in a fire-and-forget
    /// detached Task and returned, so the next `start()` could collide with the not-yet-finished stop (recorder still `recording`),
    /// throw `.alreadyRecording`, and leave the new session never recording.
    ///
    /// To make the race deterministic (no scheduling luck) the fake recorder's `stop()` is GATED: it suspends mid-stop while still
    /// marked `recording`, exactly the window the cancel's in-flight stop occupies. The restart is then driven into that window:
    /// - Unfixed code: the restart's `recorder.start()` runs immediately, sees `recording == true`, throws `.alreadyRecording`, and the
    ///   session never records (this assertion fails -> bug reproduced).
    /// - Fixed code: the restart first awaits the pending cancel-stop; releasing the gate lets that stop finish, then the start succeeds.
    func testCancelThenImmediateStartBeginsFreshSession() async {
        let config = makeConfig()
        config.sttMode = .cloud  // bypass the local readiness gate
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector
        ) {
            FakeTranscriber(text: "fresh session")
        }

        // 1) Begin a session.
        await coordinator._test_start()
        XCTAssertTrue(coordinator._test_isRecording)

        // 2) Arm the stop gate, then ESC-cancel: the cancel's in-flight stop suspends while still marked `recording`.
        await recorder.gateStop()
        coordinator._test_cancel()
        XCTAssertEqual(coordinator.phase, .idle, "取消后应立即复位到 idle")
        await recorder.waitUntilStopGated()  // ensure the cancel-stop is pinned in the "still recording" window

        // 3) Immediately start again (non-blocking) while the cancel-stop is still in flight.
        coordinator._test_handleStart()
        XCTAssertEqual(coordinator.phase, .listening, "重启应立即进入 listening")
        // Give the unfixed code's start path a chance to run and (wrongly) throw .alreadyRecording before we release the gate.
        for _ in 0..<20 { await Task.yield() }

        // 4) Release the cancel-stop, then let the restart's start Task wrap up.
        await recorder.releaseStop()
        await coordinator._test_awaitStart()

        // The restart MUST have begun a fresh recording session — not been knocked out by the unfinished cancel-stop.
        XCTAssertTrue(coordinator._test_isRecording, "取消后立即重启应可靠开始新一轮录音，而非被未完成的 stop 卡住")
        XCTAssertEqual(coordinator.phase, .listening, "重启后应保持 listening")
        let recorderRecording = await recorder.isRecording
        XCTAssertTrue(recorderRecording, "重启后录音器应处于录音中（未被半停状态遗留）")

        // 5) The fresh session must complete end-to-end: stop -> transcribe -> inject.
        await coordinator._test_stop()
        XCTAssertEqual(injector.injectedTexts, ["fresh session"], "重启的会话应能正常转写并注入")
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(coordinator._test_isRecording, "整轮结束后不应再标记为录音中")

        // The recorder must not be left half-stopped: every start was matched by a stop (cancel-stop + the restart's pipeline stop).
        let startCount = await recorder.startCount
        let stopCount = await recorder.stopCount
        XCTAssertEqual(startCount, 2, "应有两次 start：取消前一次 + 重启一次")
        XCTAssertEqual(stopCount, 2, "应有两次 stop：取消的 stop + 重启会话的管线 stop，录音器未被遗留在半停状态")
        let stillRecording = await recorder.isRecording
        XCTAssertFalse(stillRecording, "录音器最终应处于已停止状态")
    }

    // MARK: - ESC cancel mid-start: must NOT resurrect the session (startTask resurrection bug)

    /// Regression guard (startTask resurrection): when ESC-cancel lands while the recording-start Task is suspended
    /// inside `recorder.start()`, neither `awaitPendingStop()` nor `recorder.start()` throws on cancel, so without an
    /// explicit `Task.isCancelled` guard the start closure resumes after the cancel and (wrongly) sets isRecording=true
    /// + starts level forwarding while phase is already .idle — a resurrected, unstoppable session whose recorder is
    /// left running.
    ///
    /// To make the race deterministic the fake recorder's `start()` is GATED: it suspends mid-start (before flipping
    /// `recording`) exactly the window the cancel lands in. Then:
    /// - Unfixed code: the resumed closure sets isRecording=true and starts level forwarding while phase==.idle, and the
    ///   recorder is left `recording` (these assertions fail -> bug reproduced).
    /// - Fixed code: the `Task.isCancelled` guards after each await early-return; if start already succeeded the recorder
    ///   is stopped via the pending-stop path, so the device is released.
    func testCancelMidStartDoesNotResurrectSession() async {
        let config = makeConfig()
        config.sttMode = .cloud  // irrelevant here (no stop pipeline runs), keeps it off the local-readiness gate
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "should never be reached")
        }

        // 1) Arm the start gate, then kick off start WITHOUT awaiting: the start Task suspends inside recorder.start().
        await recorder.gateStart()
        coordinator._test_handleStart()
        XCTAssertEqual(coordinator.phase, .listening, "start 触发后先进入 listening")
        await recorder.waitUntilStartGated()  // ensure the start Task is pinned in the "start in flight, suspended" window
        // Capture the start Task handle BEFORE cancel nils it out, so we can deterministically await the cancelled
        // (orphaned) closure to completion after releasing the gate (otherwise _test_awaitStart is a no-op post-cancel).
        let captured = coordinator._test_startTask
        XCTAssertNotNil(captured, "handleStart 应建立 start Task")

        // 2) ESC-cancel lands while the start is suspended.
        coordinator._test_cancel()
        XCTAssertEqual(coordinator.phase, .idle, "取消后应立即复位到 idle")
        XCTAssertFalse(coordinator._test_isRecording, "取消后不应标记为录音中")

        // 3) Release the gated start, then let the (cancelled) start Task run to completion.
        await recorder.releaseStart()
        await captured?.value

        // The cancelled start must NOT have resurrected the session.
        XCTAssertEqual(coordinator.phase, .idle, "取消后被恢复的 start 闭包不应把会话拉回来")
        XCTAssertFalse(coordinator._test_isRecording, "被取消的 start 不应把 isRecording 置为 true（复活会话）")
        XCTAssertFalse(coordinator._test_hasLevelTask, "被取消的 start 不应启动电平转发（复活会话）")

        // The device must be released: if recorder.start() already succeeded before the cancel was observed, the recorder
        // must be stopped (via the pending-stop path) rather than left recording.
        let recorderRecording = await recorder.isRecording
        XCTAssertFalse(recorderRecording, "取消后录音器必须被释放（已停止），而非被遗留在录音中")

        // Nothing was injected (cancel injects nothing).
        XCTAssertTrue(injector.injectedTexts.isEmpty, "取消绝不应注入任何文本")
    }

    /// Companion to the resurrection guard: a cancel landing while the start Task is suspended at `awaitPendingStop()`
    /// (BEFORE recorder.start() is even called) must also early-return — no recorder start, no recording mark, no level
    /// forwarding. This exercises the FIRST `Task.isCancelled` guard (after awaitPendingStop) independently.
    func testCancelMidStartBeforeRecorderStartNeverStartsRecorder() async {
        let config = makeConfig()
        // Seed a pending stop that the start Task will await: begin then immediately cancel a prior session, then
        // gate the NEXT stop so awaitPendingStop suspends. Simpler: gate the stop, run a session, cancel it (stop
        // suspends), then drive a fresh start whose awaitPendingStop blocks on that gated stop, and cancel mid-await.
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "unused")
        }

        // 1) Begin and gate-cancel a session so a pending stop is in flight (suspended on the gate).
        await coordinator._test_start()
        await recorder.gateStop()
        coordinator._test_cancel()
        await recorder.waitUntilStopGated()

        // 2) Start again: its awaitPendingStop() suspends on the still-gated cancel-stop (before recorder.start()).
        coordinator._test_handleStart()
        XCTAssertEqual(coordinator.phase, .listening)
        for _ in 0..<20 { await Task.yield() }  // let the restart reach the awaitPendingStop suspension

        // 3) Cancel the restart while it is suspended at awaitPendingStop (before recorder.start()).
        coordinator._test_cancel()
        XCTAssertEqual(coordinator.phase, .idle)

        // 4) Release the original cancel-stop and let the (cancelled) restart Task finish.
        await recorder.releaseStop()
        await coordinator._test_awaitStart()

        XCTAssertEqual(coordinator.phase, .idle, "取消后被恢复的 start 闭包不应拉回会话")
        XCTAssertFalse(coordinator._test_isRecording, "在 awaitPendingStop 处被取消不应起录音")
        XCTAssertFalse(coordinator._test_hasLevelTask, "在 awaitPendingStop 处被取消不应启动电平转发")
        // The restart's recorder.start() must never have run: only the first session's one start happened.
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 1, "在 recorder.start() 之前被取消，不应再次调用 recorder.start()")
        let recorderRecording = await recorder.isRecording
        XCTAssertFalse(recorderRecording, "录音器最终应处于已停止状态")
    }

    // MARK: - Single-tap toggle resync: cancel / start-failure resets the hotkey toggle (no wasted next tap)

    /// Regression guard (single-tap toggle desync): in single-tap-toggle mode the hotkey state machine's `isActive`
    /// toggle is the SOLE start/stop driver. After ESC-cancel the coordinator must call
    /// `HotkeyManager.sessionDidEndExternally()` so the toggle returns to inactive — otherwise the user's NEXT tap would
    /// emit a phantom `.stop` against the now-idle coordinator and be silently wasted (forcing a double tap to resume).
    func testCancelResetsSingleTapToggleSoNextTapStarts() async {
        let config = makeConfig()
        config.interactionMode = .singleTap
        let manager = HotkeyManager(mode: .singleTapToggle)
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeToggleCoordinator(config: config, hotkeyManager: manager,
                                                recorder: recorder, injector: injector)

        // First isolated tap activates the toggle (-> would emit .start) and the coordinator begins a session.
        XCTAssertEqual(manager._test_emitSingleTap(), .start, "首个孤立轻点应 .start 并激活切换状态")
        XCTAssertTrue(manager._test_singleTapSessionActive, "首个轻点后切换状态应为激活")
        await coordinator._test_start()

        // ESC-cancel: the coordinator must resync the toggle back to inactive.
        coordinator._test_cancel()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(manager._test_singleTapSessionActive,
                       "取消后协调器应重置单击切换状态机，使下一次轻点重新 .start 而非被吞")
        // Proof of resync: the NEXT tap emits .start again (not a wasted phantom .stop).
        XCTAssertEqual(manager._test_emitSingleTap(), .start, "取消后下一次轻点应重新 .start，而非被吞成无效的 .stop")
    }

    /// Start-failure (microphone denied) in single-tap mode: the first tap flipped the toggle active, but recording
    /// never began. The coordinator's failToIdle path must resync the toggle back to inactive so the next tap starts.
    func testStartFailureResetsSingleTapToggle() async {
        let config = makeConfig()
        config.interactionMode = .singleTap
        let manager = HotkeyManager(mode: .singleTapToggle)
        let recorder = FakeAudioRecorder(samples: [0.1], startBehavior: .throwsDenied)
        let injector = FakeTextInjector()
        let coordinator = makeToggleCoordinator(config: config, hotkeyManager: manager,
                                                recorder: recorder, injector: injector)

        XCTAssertEqual(manager._test_emitSingleTap(), .start)
        XCTAssertTrue(manager._test_singleTapSessionActive)

        // The start fails (mic denied) -> failToIdle -> must resync the toggle.
        await coordinator._test_start()
        XCTAssertFalse(coordinator._test_isRecording, "启动失败不应标记录音中")
        XCTAssertFalse(manager._test_singleTapSessionActive,
                       "启动失败后应重置单击切换状态机（下一次轻点重新开始）")
        XCTAssertEqual(manager._test_emitSingleTap(), .start, "启动失败后下一次轻点应重新 .start")
    }

    /// Hold mode must be unaffected: cancel() calling sessionDidEndExternally() is a no-op for the hold machine, so a
    /// subsequent hold (keyDown -> .start) still works. Proven via the manager's hold path staying functional after cancel.
    func testCancelInHoldModeDoesNotDisturbHoldMachine() async {
        let config = makeConfig()
        config.interactionMode = .hold
        let manager = HotkeyManager(mode: .holdToTalk)
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeToggleCoordinator(config: config, hotkeyManager: manager,
                                                recorder: recorder, injector: injector)

        await coordinator._test_start()
        coordinator._test_cancel()
        // sessionDidEndExternally() only touches the single-tap machine; the single-tap toggle stays inactive (default),
        // confirming hold mode's cancel does not flip any toggle state. (Hold start/stop is driven by physical key edges.)
        XCTAssertFalse(manager._test_singleTapSessionActive)
        XCTAssertEqual(manager.mode, .holdToTalk, "hold 模式不应被取消逻辑改动")
    }

    /// Builds a coordinator wired to a caller-supplied real HotkeyManager (for the single-tap-toggle resync tests),
    /// otherwise all-Fake and gates bypassed (same conventions as ``makeCoordinator``).
    private func makeToggleCoordinator(
        config: AppConfig,
        hotkeyManager: HotkeyManager,
        recorder: FakeAudioRecorder,
        injector: FakeTextInjector
    ) -> DictationCoordinator {
        DictationCoordinator(
            config: config,
            hotkeyManager: hotkeyManager,
            recorder: recorder,
            panel: RecordingPanelController(headless: true),
            injector: injector,
            dictionaryStore: DictionaryStore(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appending(component: "sayit-coord-toggle-\(UUID().uuidString)")),
            transcriberFactory: { FakeTranscriber(text: "x") },
            accessibilityGate: { true },
            modelReadiness: { _ in true },
            transcribeTimeout: .seconds(5),
            soundCues: SilentSoundCues(),
            suggestionPanel: SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        )
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
        let panel = RecordingPanelController(headless: true)
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

    // MARK: - A3: transient delayed-hide task is owned by the latest transient and cancelled by cancel()/stop()

    /// A fresh transient (error / info) must cancel+replace any prior in-flight delayed-hide, so only the LATEST
    /// transient owns panel.hide().
    func testNewTransientCancelsPriorDelayedHide() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder()
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "x")
        }

        coordinator._test_showTransientError("first")
        XCTAssertTrue(coordinator._test_hasTransientTask, "首个 transient 应建立延迟隐藏任务")
        XCTAssertFalse(coordinator._test_transientTaskCancelled, "首个 transient 任务尚未被取消")

        // A second transient must cancel the first's sleeper (only the latest owns hide()).
        coordinator._test_showTransientError("second")
        // The CURRENT transientTask is the second (not cancelled); the first was cancelled+replaced.
        XCTAssertTrue(coordinator._test_hasTransientTask)
        XCTAssertFalse(coordinator._test_transientTaskCancelled, "最新 transient 任务不应被取消（取消的是被替换的旧任务）")
    }

    /// ESC-cancel during/after a transient must cancel the in-flight ~1.6s sleeper so a stale transient can never hide a
    /// freshly-started session's HUD.
    func testCancelCancelsInFlightTransient() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder()
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "x")
        }

        // Start a session so cancel() is not a no-op (it guards on phase != .idle).
        await coordinator._test_start()
        // Surface a transient (sets phase back to idle and starts the delayed-hide sleeper).
        coordinator._test_showTransientError("transient")
        // Capture the handle BEFORE cancel() nils it out, so we can assert it was cancelled.
        let captured = coordinator._test_transientTask
        XCTAssertNotNil(captured, "showTransient 应建立延迟隐藏任务")

        // Re-enter an active session, then cancel: the in-flight transient sleeper must be cancelled.
        await coordinator._test_start()
        coordinator._test_cancel()
        XCTAssertEqual(captured?.isCancelled, true, "取消应取消在途的 transient 延迟隐藏任务")
        XCTAssertFalse(coordinator._test_hasTransientTask, "取消后应清空 transientTask 句柄")
    }

    // MARK: - A4: failToIdle guard — no redundant recorder.stop()/pendingStop on the already-stopped path

    /// On the transcription-failure path the recorder was already stopped successfully earlier in runPipeline
    /// (isRecording already false). failToIdle must NOT run a redundant no-op recorder.stop() nor leave a misleading
    /// pendingStopTask. Assert exactly one stop and no lingering pendingStop.
    func testFailToIdleDoesNotDoubleStopOnAlreadyStoppedPath() async {
        let config = makeConfig()
        config.sttMode = .cloud  // bypass the local readiness gate so the pipeline reaches the transcribe call that fails
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(error: .transcriptionFailed(reason: "boom"))
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        // runPipeline ran recorder.stop() once (success), then transcribe threw -> failToIdle. The guard must skip a
        // second stop (recorder is already .notRecording) and leave no pendingStop the next handleStart needlessly awaits.
        let stopCount = await recorder.stopCount
        XCTAssertEqual(stopCount, 1, "已停止路径上 failToIdle 不应再多停一次（避免被吞掉的 .notRecording 空操作）")
        XCTAssertFalse(coordinator._test_hasPendingStop, "已停止路径上 failToIdle 不应遗留误导性的 pendingStop")
        XCTAssertTrue(injector.injectedTexts.isEmpty)
        XCTAssertFalse(coordinator._test_isRecording)
    }

    /// Start-failure path (microphone denied): the engine never started, so failToIdle must not stop the recorder at all
    /// (no swallowed .notRecording no-op) and leave no pendingStop.
    func testStartFailureDoesNotStopRecorderOrLeavePendingStop() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1], startBehavior: .throwsDenied)
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            FakeTranscriber(text: "unused")
        }

        await coordinator._test_start()

        let stopCount = await recorder.stopCount
        XCTAssertEqual(stopCount, 0, "启动失败（引擎未起）时 failToIdle 不应调用 recorder.stop()")
        XCTAssertFalse(coordinator._test_hasPendingStop, "启动失败路径不应遗留 pendingStop")
    }

    // MARK: - A5: cloud key read off the per-dictation main-actor hot path (cached against the cheap signature)

    /// The cloud-key reader must be invoked at most once across multiple same-config dictations (no synchronous Keychain
    /// read on the per-dictation hot path): the cached key is reused while the cheap (mode/model) components are unchanged.
    func testCloudKeyReaderNotInvokedPerDictationWhenConfigUnchanged() async {
        let config = makeConfig()
        config.sttMode = .cloud
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let readCount = Counter()
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            cloudKeyReader: { readCount.increment(); return "sk-test" }
        ) {
            FakeTranscriber(text: "云端")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        await coordinator._test_start()
        await coordinator._test_stop()
        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertEqual(readCount.value, 1,
                       "配置不变时云端密钥应缓存，跨多次听写最多读取一次（不在 @MainActor 热路径上同步读 Keychain）")
    }

    /// After a cheap (mode/model) signature change the cloud key is re-read (a rebuild is required anyway), so the cache
    /// stays correct for a model switch.
    func testCloudKeyReaderReinvokedAfterModelChange() async {
        let config = makeConfig()
        config.sttMode = .cloud
        config.cloudSTTModel = "gpt-4o-mini-transcribe"
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let readCount = Counter()
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            cloudKeyReader: { readCount.increment(); return "sk-test" }
        ) {
            FakeTranscriber(text: "云端")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertEqual(readCount.value, 1)

        // Switch the cloud model -> cheap signature changes -> the key is re-read (and the transcriber rebuilt).
        config.cloudSTTModel = "whisper-1"
        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertEqual(readCount.value, 2, "模型变更后应重新读取云端密钥（此时本就需要重建转写器）")
    }

    // MARK: - Learn from edits (Part B): arm + edit-key + diff + persist; OFF / AX-nil / expired / non-proper-noun

    /// End-to-end happy path: toggle ON + a successful inject arms the record (reader returns the baseline), an edit-key
    /// then a read-back returning a single proper-noun substitution presents a suggestion; Accept persists a
    /// `.learnedFromEdit` entry (canonical=corrected, variants=[heard]) to the store.
    func testLearnFromEditsArmEditAcceptPersistsEntry() async {
        let config = makeConfig()
        config.learnFromEditsEnabled = true
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let store = DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-learn-\(UUID().uuidString)"))
        // First read (ARM): the injected baseline. Second read (read-back): the user-corrected text (jon -> John).
        let reader = FakeFocusedTextReader(results: [
            FocusedText(value: "I met jon today", selectedLocation: 15, selectedLength: 0),   // arm baseline
            FocusedText(value: "I met John today", selectedLocation: 16, selectedLength: 0),  // edited
        ])
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            dictionaryStore: store, axReader: reader, suggestionPanel: suggestionPanel
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertEqual(injector.injectedTexts, ["I met jon today"], "应注入转写文本")
        XCTAssertTrue(coordinator._test_injectionRecordArmed, "开启后成功注入应武装一条 injection record")

        // Simulate the user editing in place (Backspace), then the debounced read-back + diff.
        await coordinator._test_handleEditKey()
        XCTAssertTrue(suggestionPanel._test_isShown, "单 token 专有名词替换应弹出建议")

        // Accept -> persist + clear the record.
        suggestionPanel._test_accept()
        // The persist runs in a detached Task off the main actor; poll the store until it lands.
        let added = await waitForEntry(in: store)
        XCTAssertEqual(added?.canonical, "John", "Accept 应以 corrected 作为 canonical 持久化")
        XCTAssertEqual(added?.variants, ["jon"], "Accept 应以 heard 作为 variant 持久化")
        XCTAssertEqual(added?.source, .learnedFromEdit, "来源应为 learnedFromEdit")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "Accept 后应清除 record")
    }

    /// Dismiss path: the same arm + edit + suggestion, but Dismiss adds NOTHING and clears the record.
    func testLearnFromEditsDismissPersistsNothing() async {
        let config = makeConfig()
        config.learnFromEditsEnabled = true
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let store = DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-learn-dismiss-\(UUID().uuidString)"))
        let reader = FakeFocusedTextReader(results: [
            FocusedText(value: "I met jon today", selectedLocation: 15, selectedLength: 0),
            FocusedText(value: "I met John today", selectedLocation: 16, selectedLength: 0),
        ])
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            dictionaryStore: store, axReader: reader, suggestionPanel: suggestionPanel
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        await coordinator._test_handleEditKey()
        XCTAssertTrue(suggestionPanel._test_isShown)

        suggestionPanel._test_dismiss()
        // Give any (erroneous) persist a chance to run, then assert the store stayed empty.
        for _ in 0..<10 { await Task.yield() }
        let entries = await store.all()
        XCTAssertTrue(entries.isEmpty, "Dismiss 不应持久化任何条目")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "Dismiss 后应清除 record")
    }

    /// Toggle OFF: ZERO behavior change. injectFinalText arms NOTHING, an edit-key is a no-op, no suggestion, store empty,
    /// and the injected text is byte-identical (reusing the empty-dictionary regression).
    func testLearnFromEditsOffArmsNothingAndNoSuggestion() async {
        let config = makeConfig()  // learnFromEditsEnabled defaults to false
        XCTAssertFalse(config.learnFromEditsEnabled, "前置：默认应为关")
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let store = DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-learn-off-\(UUID().uuidString)"))
        // A reader that WOULD yield a learnable diff if it were ever consulted — proving OFF never reads/diffs.
        let reader = FakeFocusedTextReader(results: [
            FocusedText(value: "I met jon today", selectedLocation: 15, selectedLength: 0),
            FocusedText(value: "I met John today", selectedLocation: 16, selectedLength: 0),
        ])
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            dictionaryStore: store, axReader: reader, suggestionPanel: suggestionPanel
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertEqual(injector.injectedTexts, ["I met jon today"], "OFF 时注入文本应逐字节不变（零行为变化）")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "OFF 时不应武装任何 record")
        XCTAssertEqual(reader.readCount, 0, "OFF 时绝不应进行任何 AX 读取")

        await coordinator._test_handleEditKey()
        XCTAssertFalse(suggestionPanel._test_isShown, "OFF 时编辑键应为 no-op，无建议")
        let entries = await store.all()
        XCTAssertTrue(entries.isEmpty, "OFF 时词典应保持为空")
    }

    /// AX read returns nil at ARM time (secure/unreadable field): the record is NOT armed, so a later edit-key is a no-op.
    func testLearnFromEditsAXNilAtArmDoesNotArm() async {
        let config = makeConfig()
        config.learnFromEditsEnabled = true
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = FakeFocusedTextReader(single: nil)  // unreadable everywhere
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertFalse(coordinator._test_injectionRecordArmed, "ARM 时 AX 返回 nil 不应武装 record")
        await coordinator._test_handleEditKey()
        XCTAssertFalse(suggestionPanel._test_isShown, "未武装时编辑键应无建议")
    }

    /// AX read returns nil at READ-BACK time (focus moved to a secure/unreadable field after arming): no suggestion.
    func testLearnFromEditsAXNilAtReadBackNoSuggestion() async {
        let config = makeConfig()
        config.learnFromEditsEnabled = true
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        // Read 1 (ARM) succeeds (baseline), read 2 (read-back) returns nil.
        let reader = FakeFocusedTextReader(results: [
            FocusedText(value: "I met jon today", selectedLocation: 15, selectedLength: 0),
            nil,
        ])
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertTrue(coordinator._test_injectionRecordArmed, "ARM 读成功应武装")

        await coordinator._test_handleEditKey()
        XCTAssertFalse(suggestionPanel._test_isShown, "读回 AX nil 应静默丢弃，无建议")
    }

    /// An expired record: the edit-key is ignored entirely (never interferes with typing), no suggestion.
    func testLearnFromEditsExpiredRecordIgnored() async {
        let config = makeConfig()
        config.learnFromEditsEnabled = true
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        // The read-back WOULD diff if consulted, but the expired record should short-circuit before any read.
        let reader = FakeFocusedTextReader(results: [
            FocusedText(value: "I met John today", selectedLocation: 16, selectedLength: 0),
        ])
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        // Force-arm an already-EXPIRED record (bypasses the AX arm read).
        coordinator._test_armInjectionRecord(injected: "I met jon today", expiresAt: Date(timeIntervalSinceNow: -1))
        XCTAssertTrue(coordinator._test_injectionRecordArmed)

        await coordinator._test_handleEditKey()
        XCTAssertFalse(suggestionPanel._test_isShown, "过期 record 应被忽略，无建议")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "过期 record 应被清除")
        XCTAssertEqual(reader.readCount, 0, "过期 record 应在任何读取前短路")
    }

    /// A non-proper-noun edit (cat -> dog, both common words): the detector returns nil, so no suggestion is shown.
    func testLearnFromEditsNonProperNounEditNoSuggestion() async {
        let config = makeConfig()
        config.learnFromEditsEnabled = true
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = FakeFocusedTextReader(results: [
            FocusedText(value: "the cat sat", selectedLocation: 11, selectedLength: 0),  // arm baseline
            FocusedText(value: "the dog sat", selectedLocation: 11, selectedLength: 0),  // edited (common->common)
        ])
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel
        ) {
            FakeTranscriber(text: "the cat sat")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        await coordinator._test_handleEditKey()

        XCTAssertFalse(suggestionPanel._test_isShown, "普通词->普通词（cat->dog）detector 返回 nil，不应有建议")
    }

    /// Polls the store until it has at least one entry (the Accept persist runs in a detached Task off the main actor),
    /// returning the first entry. Returns nil if none appears within the poll window.
    private func waitForEntry(in store: DictionaryStore) async -> DictionaryEntry? {
        for _ in 0..<200 {
            let entries = await store.all()
            if let first = entries.first { return first }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await store.all().first
    }
}

/// A tiny thread-safe counter for asserting injected-closure invocation counts.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}

/// A never-returning transcriber: used to verify the hard timeout protection (its transcribe sleeps until cancelled).
private actor HangingTranscriber: Transcriber {
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?, options: TranscribeOptions) async throws -> TranscriptionResult {
        // Sleep long enough (far beyond the test-injected timeout); the timeout branch cancels this task, and the CancellationError is swallowed by the timeout logic.
        try await Task.sleep(for: .seconds(3600))
        return TranscriptionResult(text: "never")
    }
}
