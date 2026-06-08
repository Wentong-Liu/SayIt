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
        XCTAssertTrue(coordinator._test_isRecording, "should be marked recording after start")
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 1)

        await coordinator._test_stop()

        XCTAssertEqual(injector.injectedTexts, ["你好世界"], "should inject the transcribed text")
        XCTAssertFalse(coordinator._test_isRecording, "should clear the recording flag after stop")
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
                       "a non-empty dictionary should thread enabled entries into the transcribe call in usageCount-ascending order (most-used last); disabled entries excluded")
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
                       "bias terms should reach the transcribe call in usageCount-ascending order (most-used last, so the token cap keeps high-frequency terms)")
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
        XCTAssertEqual(calls.first?.biasTerms, [], "an empty dictionary should pass empty bias terms (no prompt is constructed)")
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

        XCTAssertTrue(injector.injectedTexts.isEmpty, "empty audio should not inject")
        XCTAssertFalse(transcriberMade, "empty audio should not construct a transcriber")
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

        XCTAssertTrue(injector.injectedTexts.isEmpty, "an empty transcript should not inject")
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

        XCTAssertTrue(injector.injectedTexts.isEmpty, "a transcription failure should not inject")
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
        XCTAssertFalse(coordinator._test_isRecording, "a start failure should not mark recording")

        await coordinator._test_stop()
        XCTAssertTrue(injector.injectedTexts.isEmpty, "when recording never started nothing should be injected")
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

        XCTAssertEqual(factoryCallCount, 1, "the transcriber should be reused when config is unchanged; the factory constructs only once (model stays warm)")
        XCTAssertEqual(injector.injectedTexts, ["复用", "复用", "复用"], "all three dictations should inject normally")
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
        XCTAssertEqual(factoryCallCount, 2, "the transcriber should be rebuilt after the local model changes")
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

        XCTAssertFalse(transcriberMade, "when the model is not ready the transcriber should not be constructed/called (avoiding triggering a download and a hang)")
        XCTAssertTrue(injector.injectedTexts.isEmpty, "when the model is not ready nothing should be injected")
        XCTAssertFalse(coordinator._test_isRecording, "should converge to not-recording")
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

        XCTAssertEqual(injector.injectedTexts, ["云端转写结果"], "cloud mode should transcribe and inject normally")
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
        XCTAssertEqual(usedUID, "DeviceXYZ", "end-to-end dictation should use the persisted selected input device")
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
        XCTAssertNil(usedUID, "when no device is selected nil should be passed (follow the system default)")
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
        XCTAssertEqual(secondUID, "DeviceB", "a running coordinator should read the latest device selection fresh on the next dictation")
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

        XCTAssertTrue(injector.injectedTexts.isEmpty, "a timeout should not inject")
        XCTAssertFalse(coordinator._test_isRecording, "should converge to not-recording after timeout")
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

        XCTAssertTrue(injector.injectedTexts.isEmpty, "after cancel no text should ever be injected")
        XCTAssertEqual(coordinator.phase, .idle, "should reset to idle after cancel")
        XCTAssertFalse(coordinator._test_isRecording, "should no longer be marked recording after cancel")
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
        XCTAssertEqual(coordinator.phase, .idle, "should reset to idle immediately after cancel")
        await recorder.waitUntilStopGated()  // ensure the cancel-stop is pinned in the "still recording" window

        // 3) Immediately start again (non-blocking) while the cancel-stop is still in flight.
        coordinator._test_handleStart()
        XCTAssertEqual(coordinator.phase, .listening, "the restart should immediately enter listening")
        // Give the unfixed code's start path a chance to run and (wrongly) throw .alreadyRecording before we release the gate.
        for _ in 0..<20 { await Task.yield() }

        // 4) Release the cancel-stop, then let the restart's start Task wrap up.
        await recorder.releaseStop()
        await coordinator._test_awaitStart()

        // The restart MUST have begun a fresh recording session — not been knocked out by the unfinished cancel-stop.
        XCTAssertTrue(coordinator._test_isRecording, "an immediate restart after cancel should reliably begin a fresh recording session rather than be stuck on the unfinished stop")
        XCTAssertEqual(coordinator.phase, .listening, "should stay in listening after the restart")
        let recorderRecording = await recorder.isRecording
        XCTAssertTrue(recorderRecording, "after restart the recorder should be recording (not left in a half-stopped state)")

        // 5) The fresh session must complete end-to-end: stop -> transcribe -> inject.
        await coordinator._test_stop()
        XCTAssertEqual(injector.injectedTexts, ["fresh session"], "the restarted session should transcribe and inject normally")
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(coordinator._test_isRecording, "should no longer be marked recording after the whole round finishes")

        // The recorder must not be left half-stopped: every start was matched by a stop (cancel-stop + the restart's pipeline stop).
        let startCount = await recorder.startCount
        let stopCount = await recorder.stopCount
        XCTAssertEqual(startCount, 2, "there should be two starts: one before cancel + one for the restart")
        XCTAssertEqual(stopCount, 2, "there should be two stops: the cancel stop + the restart session's pipeline stop; the recorder is not left half-stopped")
        let stillRecording = await recorder.isRecording
        XCTAssertFalse(stillRecording, "the recorder should end up stopped")
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
        XCTAssertEqual(coordinator.phase, .listening, "should first enter listening after start is triggered")
        await recorder.waitUntilStartGated()  // ensure the start Task is pinned in the "start in flight, suspended" window
        // Capture the start Task handle BEFORE cancel nils it out, so we can deterministically await the cancelled
        // (orphaned) closure to completion after releasing the gate (otherwise _test_awaitStart is a no-op post-cancel).
        let captured = coordinator._test_startTask
        XCTAssertNotNil(captured, "handleStart should establish the start Task")

        // 2) ESC-cancel lands while the start is suspended.
        coordinator._test_cancel()
        XCTAssertEqual(coordinator.phase, .idle, "should reset to idle immediately after cancel")
        XCTAssertFalse(coordinator._test_isRecording, "should not be marked recording after cancel")

        // 3) Release the gated start, then let the (cancelled) start Task run to completion.
        await recorder.releaseStart()
        await captured?.value

        // The cancelled start must NOT have resurrected the session.
        XCTAssertEqual(coordinator.phase, .idle, "a resumed start closure after cancel should not resurrect the session")
        XCTAssertFalse(coordinator._test_isRecording, "a cancelled start should not set isRecording=true (resurrecting the session)")
        XCTAssertFalse(coordinator._test_hasLevelTask, "a cancelled start should not start level forwarding (resurrecting the session)")

        // The device must be released: if recorder.start() already succeeded before the cancel was observed, the recorder
        // must be stopped (via the pending-stop path) rather than left recording.
        let recorderRecording = await recorder.isRecording
        XCTAssertFalse(recorderRecording, "after cancel the recorder must be released (stopped), not left recording")

        // Nothing was injected (cancel injects nothing).
        XCTAssertTrue(injector.injectedTexts.isEmpty, "cancel should never inject any text")
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

        XCTAssertEqual(coordinator.phase, .idle, "a resumed start closure after cancel should not resurrect the session")
        XCTAssertFalse(coordinator._test_isRecording, "a cancel at awaitPendingStop should not start recording")
        XCTAssertFalse(coordinator._test_hasLevelTask, "a cancel at awaitPendingStop should not start level forwarding")
        // The restart's recorder.start() must never have run: only the first session's one start happened.
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 1, "cancelled before recorder.start(), recorder.start() should not be called again")
        let recorderRecording = await recorder.isRecording
        XCTAssertFalse(recorderRecording, "the recorder should end up stopped")
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
        XCTAssertEqual(manager._test_emitSingleTap(), .start, "the first isolated tap should .start and activate the toggle state")
        XCTAssertTrue(manager._test_singleTapSessionActive, "the toggle state should be active after the first tap")
        await coordinator._test_start()

        // ESC-cancel: the coordinator must resync the toggle back to inactive.
        coordinator._test_cancel()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(manager._test_singleTapSessionActive,
                       "after cancel the coordinator should reset the single-tap toggle state machine so the next tap .starts again rather than being swallowed")
        // Proof of resync: the NEXT tap emits .start again (not a wasted phantom .stop).
        XCTAssertEqual(manager._test_emitSingleTap(), .start, "after cancel the next tap should .start again, not be swallowed into a no-op .stop")
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
        XCTAssertFalse(coordinator._test_isRecording, "a start failure should not mark recording")
        XCTAssertFalse(manager._test_singleTapSessionActive,
                       "after a start failure the single-tap toggle state machine should be reset (the next tap starts again)")
        XCTAssertEqual(manager._test_emitSingleTap(), .start, "after a start failure the next tap should .start again")
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
        XCTAssertEqual(manager.mode, .holdToTalk, "hold mode should not be altered by the cancel logic")
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
        XCTAssertTrue(injector.injectedTexts.isEmpty, "cancel while idle should not inject")
        let stopCount = await recorder.stopCount
        XCTAssertEqual(stopCount, 0, "cancel while idle should not touch the recorder")
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
        XCTAssertTrue(coordinator._test_isRecording, "should be recording after start")

        // Simulate a real tap delivering one normalized level on this session's stream (emitLevel is nonisolated, called synchronously).
        recorder.emitLevel(0.7)

        // The forwarding task asynchronously consumes the level and switches back to the main thread to refresh the HUD; poll-wait for it to arrive (avoiding dependence on a fixed sleep).
        let forwarded = await waitForLevel(panel, atLeast: 0.69)
        XCTAssertTrue(forwarded, "a session level delivered after start should be forwarded to the HUD (level≈0.7), not stuck at 0")
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
        XCTAssertTrue(coordinator._test_hasTransientTask, "the first transient should establish a delayed-hide task")
        XCTAssertFalse(coordinator._test_transientTaskCancelled, "the first transient task should not be cancelled yet")

        // A second transient must cancel the first's sleeper (only the latest owns hide()).
        coordinator._test_showTransientError("second")
        // The CURRENT transientTask is the second (not cancelled); the first was cancelled+replaced.
        XCTAssertTrue(coordinator._test_hasTransientTask)
        XCTAssertFalse(coordinator._test_transientTaskCancelled, "the latest transient task should not be cancelled (the replaced old one is what gets cancelled)")
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
        XCTAssertNotNil(captured, "showTransient should establish a delayed-hide task")

        // Re-enter an active session, then cancel: the in-flight transient sleeper must be cancelled.
        await coordinator._test_start()
        coordinator._test_cancel()
        XCTAssertEqual(captured?.isCancelled, true, "cancel should cancel the in-flight transient delayed-hide task")
        XCTAssertFalse(coordinator._test_hasTransientTask, "the transientTask handle should be cleared after cancel")
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
        XCTAssertEqual(stopCount, 1, "on the already-stopped path failToIdle should not stop again (avoiding a swallowed .notRecording no-op)")
        XCTAssertFalse(coordinator._test_hasPendingStop, "on the already-stopped path failToIdle should not leave a misleading pendingStop")
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
        XCTAssertEqual(stopCount, 0, "on start failure (engine never started) failToIdle should not call recorder.stop()")
        XCTAssertFalse(coordinator._test_hasPendingStop, "the start-failure path should not leave a pendingStop")
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
                       "the cloud key should be cached when config is unchanged, read at most once across multiple dictations (not synchronously reading the Keychain on the @MainActor hot path)")
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
        XCTAssertEqual(readCount.value, 2, "the cloud key should be re-read after a model change (a transcriber rebuild is required anyway)")
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

        XCTAssertEqual(injector.injectedTexts, ["I met jon today"], "should inject the transcribed text")
        XCTAssertTrue(coordinator._test_injectionRecordArmed, "after enabling, a successful inject should arm one injection record")

        // Simulate the user editing in place (Backspace), then the debounced read-back + diff.
        await coordinator._test_handleEditKey()
        XCTAssertTrue(suggestionPanel._test_isShown, "a single-token proper-noun substitution should pop up a suggestion")

        // Accept -> persist + clear the record.
        suggestionPanel._test_accept()
        // The persist runs in a detached Task off the main actor; poll the store until it lands.
        let added = await waitForEntry(in: store)
        XCTAssertEqual(added?.canonical, "John", "Accept should persist corrected as the canonical")
        XCTAssertEqual(added?.variants, ["jon"], "Accept should persist heard as the variant")
        XCTAssertEqual(added?.source, .learnedFromEdit, "the source should be learnedFromEdit")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "the record should be cleared after Accept")
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
        XCTAssertTrue(entries.isEmpty, "Dismiss should not persist any entry")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "the record should be cleared after Dismiss")
    }

    /// Toggle OFF: ZERO behavior change. injectFinalText arms NOTHING, an edit-key is a no-op, no suggestion, store empty,
    /// and the injected text is byte-identical (reusing the empty-dictionary regression).
    func testLearnFromEditsOffArmsNothingAndNoSuggestion() async {
        let config = makeConfig()  // learnFromEditsEnabled defaults to false
        XCTAssertFalse(config.learnFromEditsEnabled, "precondition: the default should be off")
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

        XCTAssertEqual(injector.injectedTexts, ["I met jon today"], "when OFF the injected text should be byte-for-byte unchanged (zero behavior change)")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "when OFF no record should be armed")
        XCTAssertEqual(reader.readCount, 0, "when OFF no AX read should ever happen")

        await coordinator._test_handleEditKey()
        XCTAssertFalse(suggestionPanel._test_isShown, "when OFF the edit key should be a no-op, no suggestion")
        let entries = await store.all()
        XCTAssertTrue(entries.isEmpty, "when OFF the dictionary should stay empty")
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

        XCTAssertFalse(coordinator._test_injectionRecordArmed, "an AX nil at ARM time should not arm a record")
        await coordinator._test_handleEditKey()
        XCTAssertFalse(suggestionPanel._test_isShown, "when not armed the edit key should yield no suggestion")
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
        XCTAssertTrue(coordinator._test_injectionRecordArmed, "a successful ARM read should arm")

        await coordinator._test_handleEditKey()
        XCTAssertFalse(suggestionPanel._test_isShown, "an AX nil on read-back should be silently dropped, no suggestion")
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
        XCTAssertFalse(suggestionPanel._test_isShown, "an expired record should be ignored, no suggestion")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "an expired record should be cleared")
        XCTAssertEqual(reader.readCount, 0, "an expired record should short-circuit before any read")
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

        XCTAssertFalse(suggestionPanel._test_isShown, "common-word -> common-word (cat->dog) the detector returns nil, so there should be no suggestion")
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
