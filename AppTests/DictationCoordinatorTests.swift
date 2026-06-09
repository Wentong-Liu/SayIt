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
        modelState: @escaping () -> ModelManager.State = { .downloaded },
        transcribeTimeout: Duration = .seconds(5),
        modelLoadTimeout: Duration = .seconds(5),
        cloudKeyReader: (@Sendable () -> String)? = nil,
        axReader: FocusedTextReading? = nil,
        suggestionPanel: SuggestionPanelController? = nil,
        learnFreshness: Duration = .seconds(8),
        learnIdleAfter: Duration = .milliseconds(1),
        learnProviderFactory: (() async throws -> any LLMProvider)? = nil,
        termExtractorFactory: ((any LLMProvider) -> any LearnedTermExtracting)? = nil,
        metricsSink: ((String) -> Void)? = nil,
        transcriber: @escaping () throws -> any Transcriber
    ) -> DictationCoordinator {
        // By default inject an empty-dictionary store backed by a temp directory: an empty dictionary -> Layer 3 rewriting is identity (zero behavior change),
        // and it never touches the real user-dictionary file.
        let store = dictionaryStore ?? DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-dict-\(UUID().uuidString)"))
        // Default learn-from-edits reader returns nil (never arms) so tests that don't exercise the feature are unaffected;
        // a fresh suggestion panel avoids touching the shared singleton. The idle window defaults to ~1ms for fast tests.
        // By default the provider factory throws (no provider configured), so a compare never reaches a (real) LLM call.
        return DictationCoordinator(
            config: config,
            recorder: recorder,
            panel: panel,
            injector: injector,
            dictionaryStore: store,
            transcriberFactory: transcriber,
            accessibilityGate: { true },
            modelReadiness: modelReadiness,
            modelState: modelState,
            transcribeTimeout: transcribeTimeout,
            modelLoadTimeout: modelLoadTimeout,
            soundCues: SilentSoundCues(),
            cloudKeyReader: cloudKeyReader,
            axReader: axReader ?? FakeFocusedTextReader(single: nil),
            suggestionPanel: suggestionPanel ?? SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true),
            learnFreshness: learnFreshness,
            learnIdleAfter: learnIdleAfter,
            learnProviderFactory: learnProviderFactory ?? { throw ProviderError.missingAPIKey },
            termExtractorFactory: termExtractorFactory,
            metricsSink: metricsSink
        )
    }

    nonisolated private static func makePrewarmProbeTranscriber(
        model: String,
        onPreload prewarmStarted: XCTestExpectation
    ) -> WhisperKitTranscriber {
        WhisperKitTranscriber(model: model) { _ in
            prewarmStarted.fulfill()
            throw STTError.notReady
        }
    }

    private func createCompleteModelCache(for model: String) throws -> URL {
        let folder = ModelManager.repoCacheDirectory.appending(component: ModelManager.variant(for: model))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let package = folder.appending(component: "\(name).mlmodelc")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: package.appending(component: "coremldata.bin"))
        }
        return folder
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
        let transcriber = FakeTranscriber(text: "不应被调用")
        let coordinator = makeCoordinator(config: config, recorder: recorder, injector: injector) {
            transcriber
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "empty audio should not inject")
        let calls = await transcriber.calls
        XCTAssertTrue(calls.isEmpty, "empty audio should not call the transcriber")
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

    // MARK: - Pipeline metrics (observability only): one summary line per COMPLETED dictation, none on early exits

    /// A happy-path dictation that reaches injection emits exactly ONE parseable `pipeline:` summary line, carrying the
    /// success context (mode/polish/clip/char count). Asserts on the injected metrics sink (no system-log scraping); does
    /// NOT assert wall-clock magnitudes (timing is real and machine-dependent). chars=3 = the 3-char injected text "abc".
    func testHappyPathEmitsPipelineMetrics() async {
        let config = makeConfig(polishEnabled: false)
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        var lines: [String] = []
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            metricsSink: { lines.append($0) }
        ) {
            FakeTranscriber(text: "abc")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertEqual(injector.injectedTexts, ["abc"], "sanity: the happy path injected")
        XCTAssertEqual(lines.count, 1, "exactly one metrics line per completed dictation")
        let line = lines.first ?? ""
        XCTAssertTrue(line.hasPrefix("pipeline: "), "line should be the parseable pipeline summary: \(line)")
        XCTAssertTrue(line.contains("chars=3"), "char count of the final injected text: \(line)")
        XCTAssertTrue(line.contains("mode=local"), "local STT mode tag: \(line)")
        XCTAssertTrue(line.contains("polish=off"), "polish-off tag (polish disabled): \(line)")
        // All stage keys present (parseable key=value contract).
        for key in ["total=", "stt=", "dict=", "polish=", "inject=", "prepare=", "clip="] {
            XCTAssertTrue(line.contains(key), "summary should contain \(key): \(line)")
        }
    }

    /// An empty transcript never reaches injection, so NO metrics line is emitted — the line is never a misleading success.
    func testEmptyTranscriptEmitsNoPipelineMetrics() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        var lines: [String] = []
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            metricsSink: { lines.append($0) }
        ) {
            FakeTranscriber(text: "   \n  ")  // silence/unintelligible -> empty after trim
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "sanity: an empty transcript does not inject")
        XCTAssertTrue(lines.isEmpty, "no metrics line on an early exit that never injected")
    }

    /// A pasteboard-fallback (injection did NOT paste into the field) is NOT a completed pipeline, so no metrics line is
    /// emitted — only a genuinely injected `.success` counts.
    func testPasteboardFallbackEmitsNoPipelineMetrics() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .failedTextLeftInPasteboard(reason: "no focus"))
        var lines: [String] = []
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            metricsSink: { lines.append($0) }
        ) {
            FakeTranscriber(text: "保住的话")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertTrue(lines.isEmpty, "no metrics line when text was left in the pasteboard (not injected)")
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

    /// After a relevant STT config change, the transcriber should be rebuilt so the new setting takes effect.
    /// The local model is fixed to large-v3-turbo (no longer part of the mutable signature), so this drives
    /// the rebuild via the STT mode (local -> cloud), which is part of the transcriber signature. The
    /// injected factory returns a FakeTranscriber regardless of mode, so the signature change alone is what
    /// forces the rebuild — exactly the behavior under test.
    func testTranscriberRebuiltWhenSTTConfigChanges() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        var factoryCallCount = 0
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            cloudKeyReader: { "sk-test" }
        ) {
            factoryCallCount += 1
            return FakeTranscriber(text: "model")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertEqual(factoryCallCount, 1)

        // Switch the STT mode -> signature changes -> the next dictation should rebuild.
        config.sttMode = .cloud
        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertEqual(factoryCallCount, 2, "the transcriber should be rebuilt after a relevant STT config change")
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

    /// Regression guard: in local mode with the model not ready, never call transcription (otherwise the underlying layer triggers a download, and the HUD stays permanently stuck
    /// "transcribing"). With the new pre-flight gate the block happens at handleStart (recording never starts), so the transcriber is not constructed, nothing is injected, and it does not mark itself recording.
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
            modelReadiness: { _ in false }  // model not ready
        ) {
            transcriberMade = true
            return FakeTranscriber(text: "不应被转写")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertFalse(transcriberMade, "when the model is not ready the transcriber should not be constructed/called (avoiding triggering a download and a hang)")
        XCTAssertTrue(injector.injectedTexts.isEmpty, "when the model is not ready nothing should be injected")
        XCTAssertFalse(coordinator._test_isRecording, "should converge to not-recording")
        // The pre-flight gate blocks at handleStart, so recording never starts and is never stopped (the device is never opened — no utterance wasted).
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 0, "the pre-flight gate must block recording entirely")
    }

    /// Belt-and-suspenders: the post-record :730 backstop still converges if the model becomes not-ready AFTER recording
    /// already started (a corner the pre-flight gate cannot catch, since it reads readiness once at start). A stateful
    /// readiness closure (ready at start, not-ready by the time runPipeline checks) drives exactly that path: recording
    /// starts (startCount 1) and is stopped (stopCount 1), but transcription is never entered and nothing is injected.
    func testPostRecordBackstopConvergesWhenModelBecomesNotReadyAfterStart() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let transcriber = FakeTranscriber(text: "不应被转写")
        // The readiness flips: true on the first read (handleStart pre-flight gate passes → recording starts), false on the
        // second read (runPipeline :730 backstop → converge). A captured call counter implements that deterministically.
        let readinessCalls = ReadinessCallCounter()
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in readinessCalls.firstCallOnly() }  // true only on the first read, false thereafter
        ) {
            transcriber
        }

        await coordinator._test_start()
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 1, "the pre-flight gate passes (ready at start), so recording starts")
        await coordinator._test_stop()

        let calls = await transcriber.calls
        XCTAssertTrue(calls.isEmpty, "the post-record backstop must converge before calling the transcriber")
        XCTAssertTrue(injector.injectedTexts.isEmpty, "the backstop should inject nothing")
        XCTAssertFalse(coordinator._test_isRecording, "should converge to not-recording")
        let stopCount = await recorder.stopCount
        XCTAssertEqual(stopCount, 1, "recording is stopped to release the device")
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

    // MARK: - STT pre-flight gate: do not even RECORD when local && model not ready (never waste an utterance)

    /// The primary not-ready block lives at `handleStart`: in local mode, when the model cannot transcribe yet, the
    /// coordinator must NOT start the recorder at all (so the user never speaks a full utterance only to have it discarded).
    /// Distinct from `testLocalModelNotReadyDoesNotTranscribeOrHang`, which only proved the post-record :730 backstop.
    func testHandleStartGateBlocksRecordingWhenLocalAndModelNotReady() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let panel = RecordingPanelController(headless: true)
        var transcriberMade = false
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            panel: panel,
            modelReadiness: { _ in false }  // model not ready: the pre-flight gate must block before recording
        ) {
            transcriberMade = true
            return FakeTranscriber(text: "不该被录到")
        }

        await coordinator._test_start()

        // Immediately after start, the pre-flight gate has surfaced a non-success (.error) toast — never flipped to .listening.
        if case .error = panel.currentState {} else {
            XCTFail("the pre-flight gate should surface an .error toast, got \(panel.currentState)")
        }
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 0, "the pre-flight gate must block recording entirely — recorder.start must never be called")
        XCTAssertFalse(coordinator._test_isRecording, "must not be marked recording")

        // A subsequent stop (e.g. the second tap of single-tap-toggle) injects nothing and never constructs the transcriber.
        await coordinator._test_stop()
        XCTAssertFalse(transcriberMade, "must never construct/call the transcriber")
        XCTAssertTrue(injector.injectedTexts.isEmpty, "nothing should be injected")
    }

    /// Cloud mode must NOT be gated by local-model readiness at `handleStart`: even with `modelReadiness` false, recording
    /// starts normally (the cloud transcriber needs no local model).
    func testHandleStartGateDoesNotBlockCloudMode() async {
        let config = makeConfig()
        config.sttMode = .cloud
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in false }  // local model not ready, but cloud must record regardless
        ) {
            FakeTranscriber(text: "云端不被门禁拦")
        }

        await coordinator._test_start()
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 1, "cloud mode must record normally — the local-model pre-flight gate must not block it")
        await coordinator._test_stop()
        XCTAssertEqual(injector.injectedTexts, ["云端不被门禁拦"], "cloud mode should transcribe and inject normally")
    }

    /// Regression guard (double-download preparing-model hang): an IN-PROGRESS download must be treated as NOT ready for use
    /// even when `modelReadiness` (the disk-only ``ModelManager/isDownloaded`` check) already returns true. On a fresh first
    /// launch the load-critical CoreML weights land on disk (so `isDownloaded` flips true) BEFORE ``ModelManager/download``'s
    /// task fully resolves to `.downloaded` — the window where the old gate (which checked only `!modelReadiness`) wrongly
    /// passed, started recording, and entered the stuck `.preparingModel` HUD while a SECOND Hub snapshot stalled behind the
    /// first. The pre-flight gate must now block: never record, never enter `.preparingModel`, and surface the existing
    /// "downloading… NN%" message. If this test ever records or shows `.preparingModel`, the hang has regressed.
    func testHandleStartGateBlocksWhileModelStillDownloadingEvenIfReadinessTrue() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let panel = RecordingPanelController(headless: true)
        var transcriberMade = false
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            panel: panel,
            modelReadiness: { _ in true },  // disk weights already present (isDownloaded true)…
            modelState: { .downloading(progress: 0.73, speedBytesPerSec: nil) }  // …but the download task hasn't finished
        ) {
            transcriberMade = true
            return FakeTranscriber(text: "下载中不该被录到")
        }

        await coordinator._test_start()

        // The pre-flight gate must surface a non-success (.error) toast — never flip to .listening, never .preparingModel.
        if case .error = panel.currentState {} else {
            XCTFail("an in-progress download must block at the pre-flight gate with an .error toast, got \(panel.currentState)")
        }
        XCTAssertNotEqual(panel.currentState, .processing(progress: 0.0, phase: .preparingModel),
                          "dictating mid-download must NEVER enter the stuck 'preparing model' HUD")
        // The surfaced copy is the existing truthful downloading message with the integer percent.
        XCTAssertTrue(panel.currentState.displayText.contains("73%"),
                      "the downloading copy must include the integer percent; got: \(panel.currentState.displayText)")
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 0, "an in-progress download must block recording entirely — recorder.start must never be called")
        XCTAssertFalse(coordinator._test_isRecording, "must not be marked recording")

        // A subsequent stop (e.g. the second tap of single-tap-toggle) injects nothing and never constructs the transcriber.
        await coordinator._test_stop()
        XCTAssertFalse(transcriberMade, "must never construct/call the transcriber while the model is still downloading")
        XCTAssertTrue(injector.injectedTexts.isEmpty, "nothing should be injected while the model is still downloading")
    }

    /// When the local model is downloaded but not loaded into memory yet, the first hotkey press should prepare the
    /// model immediately instead of starting a recording that will only block after the user finishes speaking.
    func testHandleStartPreparesColdLocalModelBeforeRecording() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let panel = RecordingPanelController(headless: true)
        let transcriber = FakeTranscriber(text: "下一次才应该转写", ready: false)
        await transcriber.gatePreload()
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            panel: panel,
            modelReadiness: { _ in true },
            modelState: { .downloaded }
        ) {
            transcriber
        }

        coordinator._test_handleStart()

        var sawPreparing = false
        for _ in 0..<200 {
            if panel.currentState == .processing(progress: 0.0, phase: .preparingModel) {
                sawPreparing = true
                break
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(sawPreparing, "the first hotkey press should show 'preparing model' before any recording starts")
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 0, "a cold downloaded model should be prepared before opening the microphone")
        XCTAssertFalse(coordinator._test_isRecording, "preparing the model should not mark the coordinator as recording")
        let preloaded = await transcriber.preloadCalled
        XCTAssertTrue(preloaded, "the hotkey press should kick the local model preload immediately")
        let calls = await transcriber.calls
        XCTAssertTrue(calls.isEmpty, "preparing the model should not transcribe any audio from the first press")
        XCTAssertTrue(injector.injectedTexts.isEmpty, "preparing the model should not inject anything")

        await transcriber.releasePreload()
        await coordinator._test_awaitStart()
    }

    /// The post-record backstop (runPipeline) must ALSO treat an in-progress download as not-ready: if a download is still
    /// running by the time the pipeline checks (a corner the once-at-start pre-flight gate cannot catch — readiness true at
    /// start, download still live at stop), the backstop converges WITHOUT constructing the transcriber and WITHOUT entering
    /// `.preparingModel`, so the second-downloader race can never resurface there either.
    func testRunPipelineBackstopConvergesWhileModelStillDownloading() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        // Downloading state visible only AFTER recording has started: pre-flight gate passes (not downloading at start),
        // the runPipeline backstop sees .downloading and converges. A mutable box, flipped explicitly between start and
        // stop, drives that transition deterministically (no reliance on internal modelState() call ordering).
        let modelStateBox = MutableModelStateBox(.downloaded)
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in true },  // disk weights present throughout
            modelState: { modelStateBox.value }
        ) {
            FakeTranscriber(text: "不应被转写")
        }

        await coordinator._test_start()
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 1, "the pre-flight gate passes (not downloading at start), so recording starts")
        // The download is still in flight by the time the pipeline rechecks: flip the live state to .downloading now.
        modelStateBox.value = .downloading(progress: 0.9, speedBytesPerSec: nil)
        await coordinator._test_stop()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "the backstop must inject nothing while the model is still downloading")
        XCTAssertFalse(coordinator._test_isRecording, "should converge to not-recording")
        let stopCount = await recorder.stopCount
        XCTAssertEqual(stopCount, 1, "recording is stopped to release the device")
    }

    // MARK: - Truthful model-not-ready copy: downloading NN% vs no-model-yet, chosen by ModelManager state

    /// When the model IS downloading, the not-ready copy must be the truthful "downloading… NN%" message (with the integer
    /// percent), driven by the injected `modelState` seam — not the old always-"still downloading" string.
    func testModelNotReadyMessagePicksDownloadingWithPercent() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let panel = RecordingPanelController(headless: true)
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            panel: panel,
            modelReadiness: { _ in false },
            modelState: { .downloading(progress: 0.42, speedBytesPerSec: nil) }
        ) {
            FakeTranscriber(text: "x")
        }

        await coordinator._test_start()
        // The pre-flight gate fired and surfaced the downloading message: it must contain the integer percent.
        XCTAssertTrue(panel.currentState.displayText.contains("42%"),
                      "downloading copy must include the integer percent; got: \(panel.currentState.displayText)")
        // And it must be the downloading message, not the no-model message (assert against the resolver for the percent format).
        let expected = uiLanguageLocalized(format: "hud.modelDownloadingPct %d",
                                           defaultValue: "Local model downloading… %d%% — please wait", 42)
        XCTAssertEqual(coordinator._test_modelNotReadyMessage(), expected,
                       "should select the downloading-with-percent message")
    }

    /// When NO model is present (notDownloaded / failed), the copy must be the actionable "no local model — open Settings ▸
    /// Speech" message, not the downloading one.
    func testModelNotReadyMessagePicksNoModelWhenNotDownloaded() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector()
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in false },
            modelState: { .notDownloaded }
        ) {
            FakeTranscriber(text: "x")
        }
        let expected = uiLanguageLocalized("hud.noLocalModel",
                                           defaultValue: "No local model yet — open Settings ▸ Speech to download (or switch to Cloud).")
        XCTAssertEqual(coordinator._test_modelNotReadyMessage(), expected,
                       "notDownloaded should select the actionable no-model message")
        let failedCoordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in false },
            modelState: { .failed(reason: "boom") }
        ) {
            FakeTranscriber(text: "x")
        }
        XCTAssertEqual(failedCoordinator._test_modelNotReadyMessage(), expected,
                       "failed should also select the actionable no-model message")
    }

    // MARK: - Polish failure CATEGORY: notConfigured (missingAPIKey) vs failed (other error)

    /// The construction-error classifier must map `ProviderError.missingAPIKey` (an empty BYO key or a missing ChatGPT OAuth
    /// token) to `.notConfigured` — a fixable setup gap — and any OTHER error to `.failed` (a genuine runtime failure).
    /// Pure/static so it is deterministic regardless of the dev machine's Keychain contents.
    func testConstructionFailureCategoryDistinguishesMissingKeyFromOtherErrors() {
        XCTAssertEqual(DictationCoordinator.constructionFailureCategory(ProviderError.missingAPIKey), .notConfigured,
                       "a missing API key / OAuth token must map to .notConfigured")
        struct OtherError: Error {}
        XCTAssertEqual(DictationCoordinator.constructionFailureCategory(OtherError()), .failed,
                       "any non-missingAPIKey construction error must map to .failed")
        // A different ProviderError case is still a runtime failure, not "not configured".
        XCTAssertEqual(DictationCoordinator.constructionFailureCategory(ProviderError.invalidResponse), .failed,
                       "a non-missingAPIKey ProviderError must map to .failed")
    }

    // MARK: - injectFinalText: provider-aware, non-success copy for notConfigured / failed

    /// When polish was skipped because it is NOT configured, the post-injection hint must be provider-aware and routed
    /// through the non-success (.error) presentation — never the green .info checkmark. ChatGPT names sign-in; BYO names an API key.
    func testInjectFinalTextProviderAwareNotConfiguredCopy() {
        // ChatGPT provider -> "sign in" copy.
        let chatConfig = makeConfig(polishEnabled: true)
        chatConfig.providerKind = .chatGPT
        let panelChat = RecordingPanelController(headless: true)
        let chatCoordinator = makeCoordinator(
            config: chatConfig,
            recorder: FakeAudioRecorder(),
            injector: FakeTextInjector(result: .success(method: .pasteboard)),
            panel: panelChat
        ) { FakeTranscriber(text: "x") }
        chatCoordinator._test_injectFinalText("文本", polishCategory: .notConfigured)
        let signIn = uiLanguageLocalized("hud.insertedNoPolishSignIn",
                                         defaultValue: "Inserted without polish — sign in to ChatGPT under Settings ▸ Polish.")
        XCTAssertEqual(panelChat.currentState, .error(signIn), "ChatGPT notConfigured should show the sign-in copy via .error")

        // BYO provider (OpenAI) -> "add an API key" copy.
        let byoConfig = makeConfig(polishEnabled: true)
        byoConfig.providerKind = .openAI
        let panelByo = RecordingPanelController(headless: true)
        let byoCoordinator = makeCoordinator(
            config: byoConfig,
            recorder: FakeAudioRecorder(),
            injector: FakeTextInjector(result: .success(method: .pasteboard)),
            panel: panelByo
        ) { FakeTranscriber(text: "x") }
        byoCoordinator._test_injectFinalText("文本", polishCategory: .notConfigured)
        let addKey = uiLanguageLocalized("hud.insertedNoPolishAddKey",
                                         defaultValue: "Inserted without polish — add an API key under Settings ▸ Polish.")
        XCTAssertEqual(panelByo.currentState, .error(addKey), "BYO notConfigured should show the add-key copy via .error")
        XCTAssertNotEqual(signIn, addKey, "the two provider-aware messages must genuinely differ")
    }

    /// A genuine runtime polish failure (.failed) keeps the generic "polish failed, used original text" copy, but routed
    /// through the non-success (.error) presentation — a failure must never render as a green success checkmark.
    func testInjectFinalTextFailedShowsGenericCopyViaError() {
        let config = makeConfig(polishEnabled: true)
        let panel = RecordingPanelController(headless: true)
        let coordinator = makeCoordinator(
            config: config,
            recorder: FakeAudioRecorder(),
            injector: FakeTextInjector(result: .success(method: .pasteboard)),
            panel: panel
        ) { FakeTranscriber(text: "x") }
        coordinator._test_injectFinalText("文本", polishCategory: .failed)
        let generic = uiLanguageLocalized("hud.injectedPolishFailed",
                                          defaultValue: "Inserted (polish failed, used original text)")
        XCTAssertEqual(panel.currentState, .error(generic),
                       "a genuine polish failure should show the generic copy via the non-success .error presentation")
    }

    /// When polish is intentionally OFF / succeeded (.none), insertion stays SILENT — no toast (success path untouched).
    func testInjectFinalTextNoneInsertsSilently() {
        let config = makeConfig()
        let panel = RecordingPanelController(headless: true)
        let coordinator = makeCoordinator(
            config: config,
            recorder: FakeAudioRecorder(),
            injector: FakeTextInjector(result: .success(method: .pasteboard)),
            panel: panel
        ) { FakeTranscriber(text: "x") }
        coordinator._test_injectFinalText("文本", polishCategory: .none)
        // .none hides the panel (no transient toast started).
        XCTAssertFalse(coordinator._test_hasTransientTask, "the .none category must not start a transient toast (silent insertion)")
        XCTAssertEqual(panel.currentState, .idle, "after a silent insertion the panel converges to idle (hidden)")
    }

    // MARK: - Cold-start "Preparing model…" HUD state while the local model loads into memory

    /// On a COLD local-model start (model downloaded — the download gate passes — but the CoreML engine not yet loaded into
    /// memory), the hotkey press must show "preparing model" and AWAIT the load BEFORE opening the microphone. The first press
    /// prepares only; after the model is warm, the next press records and transcribes normally.
    ///
    /// Determinism (no scheduling luck): the fake transcriber reports `isReady=false` and its `preload()` is GATED — it
    /// suspends until the test releases it, pinning the "preparing model" window so the test can observe the HUD state before
    /// the load completes (mirrors the recorder stop/start gates). After release the load finishes, `isReady` flips true, and
    /// the following dictation transcribes + injects.
    func testColdLocalModelPreparesOnFirstPressThenNextPressTranscribes() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let panel = RecordingPanelController(headless: true)
        // Not yet loaded into memory: isReady=false until the gated preload() completes.
        let transcriber = FakeTranscriber(text: "冷启动转写结果", ready: false)
        await transcriber.gatePreload()
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            panel: panel,
            modelReadiness: { _ in true }  // download gate passes; the cold-start (in-memory load) gate is what we exercise
        ) {
            transcriber
        }

        coordinator._test_handleStart()

        // The start path reaches the cold-start gate and pushes the preparing-model state; poll until the panel shows it.
        var sawPreparing = false
        for _ in 0..<200 {
            if panel.currentState == .processing(progress: 0.0, phase: .preparingModel) {
                sawPreparing = true
                break
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(sawPreparing, "a cold local-model start should show the 'preparing model' HUD phase before recording")
        // The copy follows the UI language via the same localized helper as every other HUD state: compare against the
        // resolver's output for the current persisted language (rather than hardcoding a locale) so this holds in en or zh.
        let expectedCopy = UILanguageLocalizer.string("hud.preparingModel", defaultValue: "Preparing model…", bundle: .module)
        XCTAssertEqual(panel.currentState.displayText, expectedCopy,
                       "the preparing-model phase copy should be the UI-language-localized hud.preparingModel string")
        XCTAssertNotEqual(expectedCopy, "Transcribing…", "the preparing copy must be distinct from the transcribing copy")
        let firstStartCount = await recorder.startCount
        XCTAssertEqual(firstStartCount, 0, "a cold first press prepares the model before opening the microphone")

        // Release the gated load: the model finishes loading, and the first press returns to idle without recording.
        await transcriber.releasePreload()
        await coordinator._test_awaitStart()

        let preloaded = await transcriber.preloadCalled
        XCTAssertTrue(preloaded, "the cold-start gate should have awaited preload() before recording")
        XCTAssertTrue(injector.injectedTexts.isEmpty, "the preparing press should not inject anything")
        XCTAssertEqual(coordinator.phase, .idle, "after preparing, the coordinator should return to idle for the next hotkey press")

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertEqual(injector.injectedTexts, ["冷启动转写结果"],
                       "after the model loads, the next dictation should transcribe and inject normally")
    }

    /// When the local model is already WARM (isReady=true — the common case after opportunistic prewarm), the cold-start gate
    /// is skipped entirely: preload() is NOT called and no "preparing model" flash is shown — behavior is byte-identical to
    /// before this feature. (A warm transcriber whose preload() would record a call lets us assert it was never invoked.)
    func testWarmLocalModelSkipsPreparingAndDoesNotPreload() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        // Already loaded into memory: isReady=true from the start, so the cold-start gate must be skipped.
        let transcriber = FakeTranscriber(text: "热启动转写结果", ready: true)
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in true }
        ) {
            transcriber
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        let preloaded = await transcriber.preloadCalled
        XCTAssertFalse(preloaded, "a warm model must skip the cold-start gate — preload() should never be called (no preparing flash)")
        XCTAssertEqual(injector.injectedTexts, ["热启动转写结果"], "a warm model should transcribe and inject normally")
    }

    // MARK: - Preparing-model hang: bounded prepare wait abandons the WAIT (never the load), no hang, non-alarming

    /// Regression guard (preparing-model hang, fixes 1+2): when the cold-start model load is NON-cancellable and never
    /// returns within the bound, the prepare WAIT must elapse and converge to idle with a NON-alarming hint — WITHOUT
    /// hanging (the old `withThrowingTaskGroup` awaited the un-stoppable load at scope exit, defeating the timeout). The
    /// fake's `preload()` is GATED and NEVER released, so it never returns (modelling the multi-minute first-ever ANE
    /// compile); the bounded wait elapses, the pipeline shows the "still preparing" copy (NOT "Transcription failed"),
    /// converges to idle, and injects nothing. The detached load is NOT cancelled, so `preloadCalled` stays true (it keeps
    /// running + caching so a retry would be warm). If this test ever HANGS, the defeated-timeout bug has regressed.
    func testColdLocalModelBoundedPrepareConvergesToIdleAndDoesNotHang() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let panel = RecordingPanelController(headless: true)
        let transcriber = FakeTranscriber(text: "不应被转写", ready: false)
        await transcriber.gatePreload()   // gate and NEVER release: preload() never returns (non-cancellable cold load)
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            panel: panel,
            modelReadiness: { _ in true },     // download gate passes; the cold in-memory load is what hangs
            modelLoadTimeout: .milliseconds(50)  // tiny bound so the wait elapses fast
        ) {
            transcriber
        }

        await coordinator._test_start()
        // Awaiting the first start must NOT hang: the bounded wait elapses (~50ms) even though preload() never returns.

        XCTAssertTrue(injector.injectedTexts.isEmpty, "a still-preparing convergence must inject nothing")
        XCTAssertEqual(coordinator.phase, .idle, "the bounded prepare wait must converge to idle (never stuck)")
        // The HUD shows the NON-alarming "still preparing" copy, NOT the scary "Transcription failed".
        let stillPreparing = uiLanguageLocalized("hud.modelStillPreparing",
                                                 defaultValue: "Model is still preparing — try again in a moment")
        let failed = uiLanguageLocalized("hud.transcriptionFailed", defaultValue: "Transcription failed")
        XCTAssertEqual(panel.currentState, .error(stillPreparing),
                       "the bounded-wait elapse must show the non-alarming still-preparing hint")
        XCTAssertNotEqual(panel.currentState.displayText, failed,
                          "the bounded-wait elapse must NOT show the scary transcription-failed copy")
        // The detached load was kicked and is NOT cancelled — it keeps running so a retry is warm.
        let preloaded = await transcriber.preloadCalled
        XCTAssertTrue(preloaded, "the cold-start load must have been kicked (and keeps running detached)")
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 0, "a still-preparing first press should not open the microphone")
        // Release the gate so the lingering detached load task can finish (test hygiene; no behavior assertion).
        await transcriber.releasePreload()
    }

    /// Regression guard (preparing-model hang, fix 2): ESC during the preparing phase must IMMEDIATELY abort the WAIT and
    /// converge to idle injecting nothing; and a LATE bounded-wait elapse / load completion that resolves AFTER the cancel
    /// must NOT re-show any HUD or error (the old defeated timeout threw minutes later and re-flashed "Transcription
    /// failed"). The fake's `preload()` is gated; the test cancels while the prepare wait is in flight, then waits PAST the
    /// (tiny) bound and releases the load — asserting the panel stays hidden (idle) the whole time and nothing is injected.
    func testCancelDuringPreparingAbortsAndDoesNotReShowAfterLateResolve() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let panel = RecordingPanelController(headless: true)
        let transcriber = FakeTranscriber(text: "不应被转写", ready: false)
        await transcriber.gatePreload()
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            panel: panel,
            modelReadiness: { _ in true },
            modelLoadTimeout: .milliseconds(40)
        ) {
            transcriber
        }

        coordinator._test_handleStart()
        // Wait until the start task is sitting in the gated preload (the preparing-model window).
        await transcriber.waitUntilPreloadGated()
        XCTAssertEqual(panel.currentState, .processing(progress: 0.0, phase: .preparingModel),
                       "sanity: the HUD shows the preparing-model phase before cancel")
        let captured = coordinator._test_startTask

        // ESC mid-prepare: must abort the wait promptly and hide the HUD.
        coordinator._test_cancel()
        await captured?.value
        XCTAssertEqual(coordinator.phase, .idle, "ESC during preparing must converge to idle")
        XCTAssertFalse(panel.currentState.isVisible, "ESC must hide the HUD (panel idle) during preparing")

        // Wait PAST the bound and release the gated load, so any late finisher (timeout elapse / load completion) fires
        // AFTER the cancel — it must NOT re-show the HUD or an error.
        try? await Task.sleep(for: .milliseconds(120))
        await transcriber.releasePreload()
        for _ in 0..<50 { await Task.yield(); try? await Task.sleep(for: .milliseconds(2)) }

        XCTAssertTrue(injector.injectedTexts.isEmpty, "after cancel nothing should ever be injected")
        XCTAssertEqual(coordinator.phase, .idle, "a late timeout/completion after cancel must keep phase idle")
        XCTAssertFalse(panel.currentState.isVisible,
                       "a late timeout/completion after cancel must NOT re-show any HUD or error")
    }

    // MARK: - Patient cold-load wait: first compile may exceed transcribeTimeout but completes within modelLoadTimeout

    /// Regression guard (patient cold-load, fix 1): the FIRST-ever cold model load is a Core ML / ANE compile that can
    /// legitimately take >transcribeTimeout. The `.preparingModel` wait is bounded by the SEPARATE, generous
    /// ``modelLoadTimeout`` — NOT ``transcribeTimeout`` — so a preload that takes LONGER than `transcribeTimeout` but
    /// finishes within `modelLoadTimeout` must STILL succeed with NO forced "Model is still preparing — try again" retry.
    /// With the hotkey-time prepare flow, the first press prepares only; the next warm press records and transcribes.
    func testColdLoadLongerThanTranscribeTimeoutButWithinModelLoadTimeoutPreparesForNextPress() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let panel = RecordingPanelController(headless: true)
        let transcriber = FakeTranscriber(text: "首次冷启动转写结果", ready: false)
        await transcriber.gatePreload()
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            panel: panel,
            modelReadiness: { _ in true },
            transcribeTimeout: .milliseconds(40),   // SHORT transcribe bound: would have cut off the preparing wait under the bug
            modelLoadTimeout: .seconds(30)           // generous cold-load bound: the patient wait the preload finishes within
        ) {
            transcriber
        }

        coordinator._test_handleStart()
        // Sit in the gated preparing window past the (tiny) transcribeTimeout, proving the preparing wait is NOT bounded by it.
        await transcriber.waitUntilPreloadGated()
        XCTAssertEqual(panel.currentState, .processing(progress: 0.0, phase: .preparingModel),
                       "sanity: the HUD shows the preparing-model phase while the cold load is in flight")
        try? await Task.sleep(for: .milliseconds(120))   // > transcribeTimeout (40ms): under the bug the wait already elapsed
        // The cold load finishes (well within modelLoadTimeout): the patient wait prepares the next dictation.
        await transcriber.releasePreload()
        await coordinator._test_awaitStart()

        XCTAssertTrue(injector.injectedTexts.isEmpty, "the preparing press should not inject")
        XCTAssertEqual(coordinator.phase, .idle, "the first press converges to idle after the patient cold load prepares")
        // It must NOT have shown the "still preparing — try again" forced-retry hint.
        let stillPreparing = uiLanguageLocalized("hud.modelStillPreparing",
                                                 defaultValue: "Model is still preparing — try again in a moment")
        XCTAssertNotEqual(panel.currentState, .error(stillPreparing),
                          "a patient cold load that completes must NOT surface the still-preparing forced-retry hint")

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertEqual(injector.injectedTexts, ["首次冷启动转写结果"],
                       "after the patient prepare finishes, the next dictation should transcribe normally")
    }

    /// Regression guard (patient cold-load, fix 1 safety net): ``modelLoadTimeout`` is the bound that STILL applies to the
    /// preparing wait — a cold load that never returns within `modelLoadTimeout` must elapse and converge to the
    /// non-alarming still-preparing hint (never hang). The fake's `preload()` is gated and NEVER released; with a tiny
    /// `modelLoadTimeout` the patient wait elapses fast, injects nothing, and shows the still-preparing copy. This is the
    /// "still a safety net against a true infinite hang" half of decoupling the two timeouts.
    func testColdLoadExceedingModelLoadTimeoutConvergesToStillPreparing() async {
        let config = makeConfig()
        config.sttMode = .local
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let panel = RecordingPanelController(headless: true)
        let transcriber = FakeTranscriber(text: "不应被转写", ready: false)
        await transcriber.gatePreload()   // gate and NEVER release: preload() never returns
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            panel: panel,
            modelReadiness: { _ in true },
            transcribeTimeout: .seconds(30),     // long transcribe bound: proves the preparing wait is bounded by modelLoadTimeout, NOT this
            modelLoadTimeout: .milliseconds(50)   // tiny cold-load bound so the safety-net elapses fast
        ) {
            transcriber
        }

        await coordinator._test_start()
        // Must NOT hang despite the 30s transcribeTimeout: the preparing wait is bounded by the 50ms modelLoadTimeout.

        XCTAssertTrue(injector.injectedTexts.isEmpty, "a cold load exceeding modelLoadTimeout must inject nothing")
        XCTAssertEqual(coordinator.phase, .idle, "the modelLoadTimeout safety net must converge to idle (never stuck)")
        let stillPreparing = uiLanguageLocalized("hud.modelStillPreparing",
                                                 defaultValue: "Model is still preparing — try again in a moment")
        XCTAssertEqual(panel.currentState, .error(stillPreparing),
                       "exceeding modelLoadTimeout must show the non-alarming still-preparing hint")
        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 0, "a timed-out prepare should not open the microphone")
        await transcriber.releasePreload()  // test hygiene: let the lingering detached load finish
    }

    // MARK: - Prewarm on download completion

    func testModelDownloadedNotificationPrewarmsLocalTranscriber() async throws {
        let config = makeConfig()
        config.sttMode = .local
        let model = "sayit-test-prewarm-\(UUID().uuidString)"
        config.localModel = model
        let modelFolder = try createCompleteModelCache(for: model)
        defer { try? FileManager.default.removeItem(at: modelFolder) }

        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let prewarmStarted = expectation(description: "download completion starts WhisperKit preload")
        var modelReady = false
        let coordinator = makeCoordinator(
            config: config,
            recorder: recorder,
            injector: injector,
            modelReadiness: { _ in modelReady },
            modelState: { modelReady ? .downloaded : .notDownloaded }
        ) {
            Self.makePrewarmProbeTranscriber(model: model, onPreload: prewarmStarted)
        }

        coordinator.start()
        defer { coordinator.stop() }

        modelReady = true
        NotificationCenter.default.post(
            name: ModelManager.didDownloadNotification,
            object: ModelManager.shared)

        await fulfillment(of: [prewarmStarted], timeout: 1.0)
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

    // MARK: - Learn from edits (Part B v2): arm + commit/idle/focus-loss trigger + LLM extract + guard + persist

    /// A reader queuing the ARM baseline read then the read-back (edited) value: a small helper so the learn tests stay readable.
    private func learnReader(armed: String, edited: String) -> FakeFocusedTextReader {
        FakeFocusedTextReader(results: [
            FocusedText(value: armed, selectedLocation: nil, selectedLength: nil),    // arm baseline
            FocusedText(value: edited, selectedLocation: nil, selectedLength: nil),   // final (edited)
        ])
    }

    /// End-to-end happy path (TRIGGER ON COMMIT): a successful inject arms the record; a commit key fires the compare; the
    /// LLM extractor returns a single corrected term; the suggestion shows that single term; Accept persists a
    /// `.learnedFromEdit` entry (canonical=corrected, variants=[heard]) to the store.
    func testLearnFromEditsCommitExtractAcceptPersistsEntry() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let store = DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-learn-\(UUID().uuidString)"))
        let reader = learnReader(armed: "我之前用过Type+和闪电书。", edited: "我之前用过Typeless和闪电书。")
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "Type+", corrected: "Typeless"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            dictionaryStore: store, axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "我之前用过Type+和闪电书。")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertEqual(injector.injectedTexts, ["我之前用过Type+和闪电书。"], "should inject the transcribed text")
        XCTAssertTrue(coordinator._test_injectionRecordArmed, "a successful inject should arm one injection record")

        // A real edit (Backspace) is the necessary gate before a compare can fire.
        coordinator._test_handleEditKey()
        // Commit (Return) -> the compare fires, the extractor runs, the suggestion shows the SINGLE term.
        await coordinator._test_handleCommitKey()
        XCTAssertEqual(extractor.callCount, 1, "the commit trigger should call the extractor once")
        XCTAssertEqual(extractor.calls.first?.final, "我之前用过Typeless和闪电书。", "the extractor should receive the final edited text")
        XCTAssertTrue(suggestionPanel._test_isShown, "a single-term correction should pop up a suggestion")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "the record is consumed once on the first trigger")

        // Accept -> persist + clear.
        suggestionPanel._test_accept()
        let added = await waitForEntry(in: store)
        XCTAssertEqual(added?.canonical, "Typeless", "Accept should persist corrected as the canonical")
        XCTAssertEqual(added?.variants, ["Type+"], "Accept should persist heard as the variant")
        XCTAssertEqual(added?.source, .learnedFromEdit, "the source should be learnedFromEdit")
    }

    /// TRIGGER ON IDLE: with a tiny `learnIdleAfter`, the compare fires after the user pauses (no commit key), shows the
    /// suggestion, and the extractor is called once.
    func testLearnFromEditsIdleTrigger() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = learnReader(armed: "I met jon today", edited: "I met John today")
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnIdleAfter: .milliseconds(1),
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertTrue(coordinator._test_injectionRecordArmed)

        // A real edit (Backspace) is the necessary gate before a compare can fire.
        coordinator._test_handleEditKey()
        // The idle timer (~1ms) fires on its own; await it + the extraction it kicks off.
        await coordinator._test_awaitIdleCompare()
        XCTAssertEqual(extractor.callCount, 1, "the idle trigger should call the extractor once")
        XCTAssertTrue(suggestionPanel._test_isShown, "the idle-triggered compare should show a suggestion")
    }

    /// TRIGGER ON FOCUS LOSS: a focus-loss (app deactivation) while armed fires the compare and shows the suggestion.
    func testLearnFromEditsFocusLossTrigger() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = learnReader(armed: "I use sequoia", edited: "I use Sequoia")
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "sequoia", corrected: "Sequoia"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I use sequoia")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertTrue(coordinator._test_injectionRecordArmed)

        // A real edit (Backspace) is the necessary gate before a compare can fire.
        coordinator._test_handleEditKey()
        await coordinator._test_handleFocusLoss()
        XCTAssertEqual(extractor.callCount, 1, "the focus-loss trigger should call the extractor once")
        XCTAssertTrue(suggestionPanel._test_isShown, "the focus-loss-triggered compare should show a suggestion")
    }

    /// EDIT-REQUIRED GATE (COMMIT): dictate + commit with NO edit key (no Backspace) -> the compare drops BEFORE any AX
    /// read or LLM call. A real correction must involve a delete, so without one there is nothing to learn.
    func testLearnFromEditsCommitWithoutEditKeyDropsNoCompare() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = learnReader(armed: "I met jon today", edited: "I met John today")
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertTrue(coordinator._test_injectionRecordArmed)

        // NO edit key -> the commit trigger must drop before reading AX / calling the LLM.
        await coordinator._test_handleCommitKey()
        XCTAssertEqual(extractor.callCount, 0, "with no edit key the extractor must not be called")
        XCTAssertFalse(suggestionPanel._test_isShown, "with no edit key no suggestion should appear")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "the record is still consumed once on the trigger")
    }

    /// EDIT-REQUIRED GATE (IDLE): the idle timer fires with NO edit key -> the compare drops, no extractor, no suggestion.
    func testLearnFromEditsIdleWithoutEditKeyDropsNoCompare() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = learnReader(armed: "I met jon today", edited: "I met John today")
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnIdleAfter: .milliseconds(1),
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertTrue(coordinator._test_injectionRecordArmed)

        // NO edit key -> the idle-fired compare must drop.
        await coordinator._test_awaitIdleCompare()
        XCTAssertEqual(extractor.callCount, 0, "with no edit key the idle trigger must not call the extractor")
        XCTAssertFalse(suggestionPanel._test_isShown, "with no edit key the idle trigger should show no suggestion")
    }

    /// EDIT-REQUIRED GATE (FOCUS LOSS): focus loss with NO edit key -> the compare drops, no extractor, no suggestion.
    func testLearnFromEditsFocusLossWithoutEditKeyDropsNoCompare() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = learnReader(armed: "I use sequoia", edited: "I use Sequoia")
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "sequoia", corrected: "Sequoia"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I use sequoia")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertTrue(coordinator._test_injectionRecordArmed)

        // NO edit key -> the focus-loss compare must drop.
        await coordinator._test_handleFocusLoss()
        XCTAssertEqual(extractor.callCount, 0, "with no edit key the focus-loss trigger must not call the extractor")
        XCTAssertFalse(suggestionPanel._test_isShown, "with no edit key the focus-loss trigger should show no suggestion")
    }

    /// NEXT DICTATION drops the prior armed record: a new dictation start clears the record so it never carries over.
    func testLearnFromEditsNextDictationDropsPriorRecord() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        // Arm-read for the first inject; the new dictation start should clear before any second read matters.
        let reader = FakeFocusedTextReader(results: [
            FocusedText(value: "I met jon today", selectedLocation: nil, selectedLength: nil),
        ])
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertTrue(coordinator._test_injectionRecordArmed, "the first inject arms a record")

        // A new dictation start should DROP the prior record (next-dictation policy).
        await coordinator._test_start()
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "a new dictation should drop the prior armed record")

        // A commit now is a no-op (nothing armed) -> the extractor is never called.
        await coordinator._test_handleCommitKey()
        XCTAssertEqual(extractor.callCount, 0, "after the record is dropped, a commit should not call the extractor")
        XCTAssertFalse(suggestionPanel._test_isShown)
    }

    /// LLM returns nil (not a single-term correction): no suggestion is shown.
    func testLearnFromEditsExtractorNilNoSuggestion() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = learnReader(armed: "let's meet tomorrow", edited: "let's meet on Tuesday instead")
        let extractor = FakeLearnedTermExtractor(result: nil)   // not a single-term correction
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "let's meet tomorrow")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        coordinator._test_handleEditKey()
        await coordinator._test_handleCommitKey()

        XCTAssertEqual(extractor.callCount, 1, "the extractor is still consulted")
        XCTAssertFalse(suggestionPanel._test_isShown, "a nil extraction should yield no suggestion")
    }

    /// The single-term GUARD rejects a sentence-like `corrected` even if the LLM misbehaves: no suggestion.
    func testLearnFromEditsGuardRejectsSentenceLikeCorrected() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let final = "我之前用过Typeless和闪电书。"
        let reader = learnReader(armed: "我之前用过Type+和闪电书。", edited: final)
        // A misbehaving extractor that returns the WHOLE sentence as the corrected term — the guard must reject it.
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "Type+", corrected: final))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "我之前用过Type+和闪电书。")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        coordinator._test_handleEditKey()
        await coordinator._test_handleCommitKey()

        XCTAssertFalse(suggestionPanel._test_isShown, "the hard single-term guard must reject a sentence-like corrected term")
    }

    /// NO PROVIDER configured: `learnProviderFactory` throws, so the compare drops silently — the extractor is never called.
    func testLearnFromEditsNoProviderNoSuggestion() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = learnReader(armed: "I met jon today", edited: "I met John today")
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        // learnProviderFactory defaults to throwing (no provider configured).
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        // Edit so the didEdit gate passes — the DROP under test here is the missing provider, not the no-edit gate.
        coordinator._test_handleEditKey()
        await coordinator._test_handleCommitKey()

        XCTAssertEqual(extractor.callCount, 0, "with no provider configured the extractor is never called")
        XCTAssertFalse(suggestionPanel._test_isShown, "no provider -> no suggestion")
    }

    /// finalText == injectedText (the user made no edit): the compare drops BEFORE any LLM call (no extractor invocation).
    func testLearnFromEditsIdenticalFinalNoLLMCall() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        // Both the ARM read and the read-back return the SAME (unedited) text.
        let reader = FakeFocusedTextReader(single:
            FocusedText(value: "I met jon today", selectedLocation: nil, selectedLength: nil))
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        // Edit so the didEdit gate passes — the DROP under test here is final==injected, not the no-edit gate. (A user can
        // delete then retype the same characters, leaving identical text yet having pressed Backspace.)
        coordinator._test_handleEditKey()
        await coordinator._test_handleCommitKey()

        XCTAssertEqual(extractor.callCount, 0, "an identical final text must NOT call the LLM")
        XCTAssertFalse(suggestionPanel._test_isShown, "no edit -> no suggestion")
    }

    /// Dismiss path: a shown suggestion + Dismiss adds NOTHING and the suggestion hides.
    func testLearnFromEditsDismissPersistsNothing() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let store = DictionaryStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(component: "sayit-coord-learn-dismiss-\(UUID().uuidString)"))
        let reader = learnReader(armed: "I met jon today", edited: "I met John today")
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            dictionaryStore: store, axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        coordinator._test_handleEditKey()
        await coordinator._test_handleCommitKey()
        XCTAssertTrue(suggestionPanel._test_isShown)

        suggestionPanel._test_dismiss()
        for _ in 0..<10 { await Task.yield() }
        let entries = await store.all()
        XCTAssertTrue(entries.isEmpty, "Dismiss should not persist any entry")
        XCTAssertFalse(suggestionPanel._test_isShown, "the suggestion should hide after Dismiss")
    }

    /// AX read returns nil at ARM time (secure/unreadable field): the record is NOT armed, so a later commit is a no-op.
    func testLearnFromEditsAXNilAtArmDoesNotArm() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = FakeFocusedTextReader(single: nil)  // unreadable everywhere
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()

        XCTAssertFalse(coordinator._test_injectionRecordArmed, "an AX nil at ARM time should not arm a record")
        await coordinator._test_handleCommitKey()
        XCTAssertEqual(extractor.callCount, 0, "when not armed a commit should not call the extractor")
        XCTAssertFalse(suggestionPanel._test_isShown, "when not armed the commit should yield no suggestion")
    }

    /// AX read returns nil at READ-BACK time (focus moved to a secure/unreadable field after arming): no suggestion / no LLM.
    func testLearnFromEditsAXNilAtReadBackNoSuggestion() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        // Read 1 (ARM) succeeds (baseline), read 2 (read-back) returns nil.
        let reader = FakeFocusedTextReader(results: [
            FocusedText(value: "I met jon today", selectedLocation: nil, selectedLength: nil),
            nil,
        ])
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        await coordinator._test_start()
        await coordinator._test_stop()
        XCTAssertTrue(coordinator._test_injectionRecordArmed, "a successful ARM read should arm")

        // Edit so the didEdit gate passes — the DROP under test here is the unreadable read-back, not the no-edit gate.
        coordinator._test_handleEditKey()
        await coordinator._test_handleCommitKey()
        XCTAssertEqual(extractor.callCount, 0, "an unreadable final text must NOT call the LLM")
        XCTAssertFalse(suggestionPanel._test_isShown, "an AX nil on read-back should be silently dropped, no suggestion")
    }

    /// An expired record: a commit is ignored (never interferes with typing), no read, no LLM, no suggestion.
    func testLearnFromEditsExpiredRecordIgnored() async {
        let config = makeConfig()
        let recorder = FakeAudioRecorder(samples: [0.1, 0.2])
        let injector = FakeTextInjector(result: .success(method: .pasteboard))
        let reader = FakeFocusedTextReader(results: [
            FocusedText(value: "I met John today", selectedLocation: nil, selectedLength: nil),
        ])
        let extractor = FakeLearnedTermExtractor(result: LearnedTerm(heard: "jon", corrected: "John"))
        let suggestionPanel = SuggestionPanelController(autoDismissAfter: .seconds(60), headless: true)
        let coordinator = makeCoordinator(
            config: config, recorder: recorder, injector: injector,
            axReader: reader, suggestionPanel: suggestionPanel,
            learnProviderFactory: { DummyLLMProvider() },
            termExtractorFactory: { _ in extractor }
        ) {
            FakeTranscriber(text: "I met jon today")
        }

        // Force-arm an already-EXPIRED record (bypasses the AX arm read).
        coordinator._test_armInjectionRecord(injected: "I met jon today", expiresAt: Date(timeIntervalSinceNow: -1))
        XCTAssertTrue(coordinator._test_injectionRecordArmed)

        await coordinator._test_handleCommitKey()
        XCTAssertFalse(suggestionPanel._test_isShown, "an expired record should be ignored, no suggestion")
        XCTAssertFalse(coordinator._test_injectionRecordArmed, "an expired record should be consumed/cleared")
        XCTAssertEqual(reader.readCount, 0, "an expired record should short-circuit before any read")
        XCTAssertEqual(extractor.callCount, 0, "an expired record should never call the extractor")
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

/// A tiny call counter for the model-readiness backstop test: returns true on the FIRST call and false on every call after,
/// so a single injected closure can model "ready at handleStart, not-ready by the time runPipeline rechecks".
@MainActor
private final class ReadinessCallCounter {
    private var calls = 0
    func firstCallOnly() -> Bool {
        defer { calls += 1 }
        return calls == 0
    }
}

/// A tiny mutable holder for ``ModelManager/State``: lets a test flip the live model state between coordinator calls (e.g.
/// `.downloaded` at handleStart so recording begins, then `.downloading(...)` by the time runPipeline rechecks), modelling
/// a download that is still in flight when the pipeline reaches its backstop.
@MainActor
private final class MutableModelStateBox {
    var value: ModelManager.State
    init(_ value: ModelManager.State) { self.value = value }
}

/// A never-returning transcriber: used to verify the hard timeout protection (its transcribe sleeps until cancelled).
private actor HangingTranscriber: Transcriber {
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?, options: TranscribeOptions) async throws -> TranscriptionResult {
        // Sleep long enough (far beyond the test-injected timeout); the timeout branch cancels this task, and the CancellationError is swallowed by the timeout logic.
        try await Task.sleep(for: .seconds(3600))
        return TranscriptionResult(text: "never")
    }
}
