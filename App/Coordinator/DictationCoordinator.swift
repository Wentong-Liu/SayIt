import AppKit
import SayItCore

/// End-to-end dictation orchestrator: chains hotkey -> recording -> transcription -> polish -> injection into a complete loop.
///
/// This is the App layer's single place that "wires up" the various `SayItCore` modules. All concrete capabilities reuse
/// existing types (not redeclared here):
/// - Trigger: ``HotkeyManager`` (emits `.start` / `.stop` per ``AppConfig``'s trigger key and interaction mode).
/// - Recording: ``AudioRecorder`` (`actor`, microphone -> 16kHz mono `[Float]`).
/// - Transcription: local ``WhisperKitTranscriber`` or cloud ``CloudTranscriber`` (chosen per ``STTMode``).
/// - Polish: ``PolishPipeline`` + the ``LLMProvider`` constructed by the App-layer ``ProviderFactory`` (auto-falls back to the original on failure).
/// - Injection: ``TextInjector`` (clipboard Cmd-V, injected at the focused App's cursor).
/// - Feedback: the ``RecordingPanelController`` HUD (listening / transcribing / error / idle).
///
/// Design points:
/// - The whole type is `@MainActor`: UI (HUD, menu-bar status), hotkey monitoring, and injection must all be on the main thread; time-consuming async work like transcription / polish
///   is placed in a `Task` and `await`ed, with the UI switched to `transcribing` during the process, not blocking the main thread.
/// - **Never lose the user's words**: polish failure falls back to the original (built into ``PolishPipeline``); injection failure leaves the text in the clipboard and hints.
/// - **Focus-drift protection**: records the target App at `.start`, and verifies the target is still frontmost before injection (on drift, still injects into the current frontmost,
///   but the ``TextInjector`` clipboard fallback guarantees no lost characters).
/// - **Empty transcription**: nothing said / silence -> no injection, the HUD gives a brief hint then returns to idle.
@MainActor
final class DictationCoordinator {
    /// Process-level singleton: `start()`ed by ``AppDelegate`` at launch.
    static let shared = DictationCoordinator()

    // MARK: Collaborators

    private let config: AppConfig
    private let hotkeyManager: HotkeyManager
    private let recorder: AudioRecording
    private let panel: RecordingPanelController
    private let injector: TextInjecting
    /// The polish pipeline: injects a failure-log callback for debugging (never loses characters, only observes).
    private let polishPipeline = PolishPipeline(logFailure: { reason in
        NSLog("[SayIt] 润色失败回退原文: %@", reason)
    })

    /// The high-level state observable by the menu bar / caller (distinct from the HUD's fine-grained states: this only exposes idle/listening/working).
    enum Phase: Equatable, Sendable {
        case idle
        case listening
        case working
    }

    /// Callback (main thread) for current high-level state changes, for the menu bar to lightly reflect idle/listening.
    var onPhaseChange: ((Phase) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet {
            guard oldValue != phase else { return }
            onPhaseChange?(phase)
        }
    }

    // MARK: Runtime state

    /// The injection target App recorded at `.start`, used for injection back-fill and focus-drift verification.
    private var capturedTarget: InjectionTarget?

    /// The in-progress "stop -> transcribe -> polish -> inject" task; prevents re-entry.
    private var processingTask: Task<Void, Never>?

    /// The in-progress `recorder.start()` task handle. Re-entrancy race protection for extremely short presses: `handleStop` must first `await`
    /// its completion, ensuring `stop()` does not execute on the actor before `start()` and trigger `.notRecording`.
    private var startTask: Task<Void, Never>?

    /// Whether recording has started successfully (set by the start Task after `recorder.start()` succeeds).
    private var isRecording = false

    /// The task forwarding recording levels to the HUD: **each recording session** consumes the current session's `recorder.levels`.
    /// Key: `recorder.levels` must be read only after `recorder.start()` succeeds, because `AudioRecorder`
    /// rebuilds a brand-new pair of single-consumer streams on each `start()` (see `LevelStreamHolder`); a stream captured once before start
    /// would be finished by `beginSession()`, causing the forwarding loop to spin idle, the HUD waveform to stay at 0, and the dots to go dead.
    /// This task is cancelled when recording stops, and the HUD waveform settles with the 0 produced by `stop()`.
    private var levelTask: Task<Void, Never>?

    /// Whether monitoring has started (idempotency protection).
    private var isStarted = false

    /// The long-lived task listening for hotkey events.
    private var eventLoopTask: Task<Void, Never>?

    /// The observer token for the config-change notification (registered in block form, must be removed with the token).
    private var configObserver: NSObjectProtocol?

    /// The reused warm transcriber instance: paired with ``cachedSignature``. Reused across multiple dictations when the config is unchanged,
    /// so ``WhisperKitTranscriber``'s CoreML engine loads only once and stays warm (fixing the ~10s reload of the ~1GB model per dictation).
    private var cachedTranscriber: (any Transcriber)?

    /// The relevant STT config signature from the last transcriber construction; only rebuilds when the current signature differs (local/cloud switch, local model change,
    /// cloud model/API key change). Other unrelated config changes (such as the trigger key) do not trigger a rebuild.
    private var cachedSignature: TranscriberSignature?

    /// The in-progress background prewarm task (avoiding prewarming the same instance repeatedly).
    private var preloadTask: Task<Void, Never>?

    /// A snapshot of the relevant STT config that decides whether the transcriber needs rebuilding. Contains only fields that change the transcriber's identity/behavior:
    /// `sttMode` (local/cloud), `localModel` (local model), `cloudModel` and `cloudKey` (cloud model and credentials).
    /// The language is always auto-detected and not part of the signature.
    private struct TranscriberSignature: Equatable {
        let mode: STTMode
        let localModel: String
        let cloudModel: String
        let cloudKey: String
    }

    // MARK: Initialization

    /// The transcriber factory: produces a ``Transcriber`` per the current config. Defaults to choosing the local/cloud implementation per ``STTMode``;
    /// tests can inject a factory returning ``FakeTranscriber``, to exercise the transcription/empty-transcription/transcription-failure branches.
    /// `throws` to preserve the "construction failure (e.g. cloud missing key)" semantics.
    private let transcriberFactory: () throws -> any Transcriber

    /// Accessibility authorization gate override: when non-nil, replaces the default ``ensureAccessibilityOrGuide()``.
    /// Tests inject a constant true to bypass the real authorization environment.
    private let accessibilityGateOverride: (() -> Bool)?

    /// Local model readiness detection: given a friendly model name, returns whether that model is already cached locally and can be loaded directly.
    /// By default read-only reuses ``ModelManager/isDownloaded(model:)`` (no network, no download); tests can inject it to exercise
    /// the "model not ready" branch. **Read-only** -- never triggers a download here.
    private let modelReadiness: (String) -> Bool

    /// Transcription hard timeout: `transcribe(...)` must return within this limit, otherwise it is treated as stalled and converged to an error hint.
    /// Defaults to 90s -- enough for local inference to complete on a loaded model, but guaranteeing "never permanently stuck transcribing". Tests can inject an extremely short value.
    private let transcribeTimeout: Duration

    /// - Parameters:
    ///   - config: the application config; defaults to `.shared`.
    ///   - hotkeyManager: the hotkey manager; defaults to constructing per the current config.
    ///   - recorder: the recorder; defaults to ``AudioRecorder``.
    ///   - panel: the HUD controller; defaults to the shared instance.
    ///   - injector: the text injector; defaults to ``TextInjector``.
    ///   - transcriberFactory: the transcriber factory; defaults to choosing local/cloud per the config (see ``makeConfiguredTranscriber(_:)``).
    ///   - accessibilityGate: the accessibility gate; defaults to guiding authorization on demand (see ``ensureAccessibilityOrGuide()``).
    ///   - modelReadiness: local model readiness detection; defaults to read-only reuse of ``ModelManager/isDownloaded(model:)``.
    ///   - transcribeTimeout: the transcription hard timeout; defaults to 90s.
    init(config: AppConfig = .shared,
         hotkeyManager: HotkeyManager? = nil,
         recorder: AudioRecording = AudioRecorder(),
         panel: RecordingPanelController = .shared,
         injector: TextInjecting = TextInjector(),
         transcriberFactory: (() throws -> any Transcriber)? = nil,
         accessibilityGate: (() -> Bool)? = nil,
         modelReadiness: ((String) -> Bool)? = nil,
         transcribeTimeout: Duration = .seconds(90)) {
        self.config = config
        self.recorder = recorder
        self.panel = panel
        self.injector = injector
        self.hotkeyManager = hotkeyManager
            ?? HotkeyManager(triggerKey: config.triggerKey,
                             mode: Self.hotkeyMode(for: config.interactionMode))
        // The default factory references config's current STT settings; tests can replace it wholesale.
        let cfg = config
        self.transcriberFactory = transcriberFactory ?? { try Self.makeConfiguredTranscriber(cfg) }
        self.accessibilityGateOverride = accessibilityGate
        // The default readiness detection read-only reuses ModelManager.isDownloaded (no network, no download, no modification of ModelManager).
        self.modelReadiness = modelReadiness ?? { ModelManager.isDownloaded(model: $0) }
        self.transcribeTimeout = transcribeTimeout
    }

    // MARK: Lifecycle

    /// Starts monitoring and hooks into config changes. Repeated calls are idempotent.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // After a config change (trigger key / interaction mode change), sync to the hotkey manager in real time;
        // a relevant STT config change (switching to local mode / changing the local model) opportunistically prewarms, making the next dictation fast too.
        configObserver = NotificationCenter.default.addObserver(
            forName: AppConfig.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyHotkeyConfig()
                self?.preloadLocalIfReady()
            }
        }

        applyHotkeyConfig()
        startEventLoop()
        hotkeyManager.start()
        phase = .idle

        // Start opportunistic prewarming: in local mode with the model already downloaded, load ahead of time so the first dictation is not slow either (not blocking the main thread).
        preloadLocalIfReady()
    }

    /// Stops monitoring and cleans up (usually called before App exit; not required).
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
        preloadTask?.cancel()
        preloadTask = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        panel.hide()
        phase = .idle
    }

    /// Syncs the current config (trigger key / interaction mode) to the hotkey manager.
    ///
    /// Writes back only when the value **actually changes**: because `HotkeyManager.mode`'s setter resets the internal state machine,
    /// if during a hold dictation (held, not released) an unrelated config-change notification is received and the same value is unconditionally written back, it would knock the state machine
    /// back to the start and lose the fact of "currently being held", causing the subsequent release to not produce `.stop`. Comparing before assignment avoids this.
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

    /// Starts level forwarding for **this recording session**: called after `recorder.start()` succeeds, at which point the read
    /// `recorder.levels` is the new stream rebuilt for this session (see the `levelTask` / `AudioRecorder.levels` comments).
    /// After cancelling the previous round's leftover task, builds a new task, refreshing the HUD waveform value by value on the main thread (`panel.update` on `@MainActor` is safe).
    private func startLevelForwarding() {
        levelTask?.cancel()
        // Recording has started: read the current session's stream inside the task (nonisolated, no need to enter the actor).
        let levels = recorder.levels
        levelTask = Task { [weak self] in
            for await level in levels {
                if Task.isCancelled { break }
                guard let self else { return }
                self.panel.update(level: level)
            }
        }
    }

    /// Stops and cleans up this round's level forwarding task (called when recording stops / on failure convergence).
    private func stopLevelForwarding() {
        levelTask?.cancel()
        levelTask = nil
    }

    /// Consumes the hotkey event stream: `.start` begins recording, `.stop` begins the transcription pipeline.
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

    // MARK: Loop -- start

    /// `.start`: (first time) verifies accessibility authorization -> records the target App -> starts recording -> HUD switches to listening.
    private func handleStart() {
        // When the previous round is still processing (transcribe/polish/inject), ignore the new start, to avoid overlap.
        guard processingTask == nil else { return }
        // When the last press's recording start has not wrapped up (an extremely short press), ignore another start, letting that one run its natural course.
        guard startTask == nil else { return }

        // Guide accessibility authorization on demand: pop the system dialog when the dictation key is first pressed and unauthorized (no longer disturbing at launch).
        // When unauthorized the global hotkey can be established but receives no events -- but reaching here means this one was received, so just do an informative guide.
        guard (accessibilityGateOverride ?? ensureAccessibilityOrGuide)() else { return }

        // Record the injection target (for injection back-fill + focus-drift verification).
        capturedTarget = currentFrontmostTarget()

        panel.show(state: .listening)
        phase = .listening

        startTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }
            do {
                // Start recording with the persisted input device: read config.inputDeviceUID fresh on each press,
                // letting the microphone selected in the settings page take effect immediately for the next dictation (no App restart needed).
                // nil = follow the system default (equivalent to start()); when the UID is invalid, AudioRecorder automatically falls back to the system default.
                try await self.recorder.start(deviceUID: self.config.inputDeviceUID)
                self.isRecording = true
                // Recording started: subscribe to this session's rebuilt level stream, driving the HUD dots to rise and fall with speech amplitude.
                self.startLevelForwarding()
            } catch {
                // Recording start failed (mostly microphone unauthorized): hint and converge to idle.
                self.isRecording = false
                self.failToIdle(message: Self.recordingFailureMessage(error))
            }
        }
    }

    /// Verifies accessibility authorization; if unauthorized, pops the system dialog to guide and gives the HUD a light hint, returning false (no recording this time).
    /// Returns true if authorized.
    private func ensureAccessibilityOrGuide() -> Bool {
        if AccessibilityAuthorization.isTrusted { return true }
        // Unauthorized: trigger the system authorization dialog (prompt), and give a guiding line in the HUD.
        AccessibilityAuthorization.ensureTrusted(prompting: true)
        showTransientError(String(localized: "hud.needAccessibility",
                                  defaultValue: "Accessibility permission required — enable it in System Settings"))
        return false
    }

    // MARK: Loop -- end -> transcribe -> polish -> inject

    /// `.stop`: stops recording to get samples, then transcribe -> polish -> inject.
    private func handleStop() {
        // Ignore if already processing.
        guard processingTask == nil else { return }
        // Extremely-short-press race: `.stop` may closely follow `.start`, at which point the recording start Task may not have finished yet.
        // Take the start handle first, then `await` its completion after entering the pipeline, ensuring stop does not execute on the actor before start.
        let pendingStart = startTask

        // Enter the processing state: start from the transcribing phase, progress 0.0 (Typeless-style progress bar 0...0.5 = transcribing).
        updateProcessing(0.0, .transcribing)
        phase = .working

        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.processingTask = nil }
            await self.runPipeline(awaiting: pendingStart)
        }
    }

    /// The complete pipeline: stop recording -> transcribe -> (optional) polish -> inject. Runs in a background task, switching back to the main thread for UI calls.
    /// - Parameter pendingStart: this round's recording start Task (may still be in progress); `await` its completion before stopping.
    private func runPipeline(awaiting pendingStart: Task<Void, Never>?) async {
        // 0) Wait for the recording start to wrap up, to avoid stop triggering `.notRecording` before start.
        await pendingStart?.value

        // On start failure (e.g. microphone denied) isRecording is still false: the start path already hinted and converged, so just exit here.
        guard isRecording else {
            panel.hide()
            phase = .idle
            return
        }

        // 1) Stop recording, take the samples. After stopping, level forwarding is meaningless (stop() already produced 0 to settle the waveform): clear the forwarding task.
        let samples: [Float]
        do {
            samples = try await recorder.stop()
            isRecording = false
            stopLevelForwarding()
        } catch {
            isRecording = false
            failToIdle(message: String(localized: "hud.stopRecordingFailed",
                                       defaultValue: "Failed to finish recording"))
            return
        }

        // Empty audio (nothing said): do not transcribe, do not inject, briefly hint then idle.
        guard !samples.isEmpty else {
            emptyToIdle()
            return
        }

        // 1.5) Local model readiness gate: local transcription depends on the WhisperKit engine, and the engine downloads first when the model is not cached
        // (possibly taking several minutes), during which the HUD stays stuck at "transcribing", appearing permanently frozen. Here, before calling transcribe,
        // **read-only** check whether the model is downloaded (no network, no triggering a download), and if not ready, give a clear hint and converge to idle,
        // never entering the local transcription path that would trigger a download. Cloud mode is not affected by this gate.
        if config.sttMode == .local, !modelReadiness(config.localModel) {
            modelNotReadyToIdle()
            return
        }

        // 2) Transcribe (wrapped with a hard timeout: transcribe must return within transcribeTimeout, otherwise treated as stalled and converged to an error,
        //    guaranteeing the HUD "never permanently stuck transcribing" -- even if a race/corner case occurs between the readiness check above and the real load).
        let transcript: String
        do {
            let transcriber = try currentTranscriber()
            // Speech recognition always auto-detects the language (T24): always passes nil to let the backend judge by the speech, no longer reading AppConfig.language.
            let result = try await withTranscribeTimeout {
                try await transcriber.transcribe(
                    samples,
                    sampleRate: AudioFormat.sampleRate,
                    language: nil
                )
            }
            transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is TranscribeTimeout {
            // Hard timeout: transcription does not return in time (e.g. the underlying layer stuck loading/downloading the model). Give an error hint and converge to idle.
            failToIdle(message: String(localized: "hud.transcriptionFailed", defaultValue: "Transcription failed"))
            return
        } catch let error as STTError {
            failToIdle(message: Self.transcriptionFailureMessage(error))
            return
        } catch {
            failToIdle(message: String(localized: "hud.transcriptionFailed", defaultValue: "Transcription failed"))
            return
        }

        // Empty transcription (silence / unintelligible): no injection, briefly hint then idle.
        guard !transcript.isEmpty else {
            emptyToIdle()
            return
        }

        // Transcription done: reaching the 50% boundary of the progress bar. With polish on, flip into the polish phase (0.5...1);
        // with polish off, per requirements transcription completion fills directly to 1.0 (the polish phase is not shown).
        if config.polishEnabled {
            updateProcessing(0.5, .polishing)
        } else {
            updateProcessing(1.0, .transcribing)
        }

        // 3) Polish (on -> go through the LLM, auto-falls back to the original on failure/off, built into PolishPipeline).
        let polished = await polishIfEnabled(transcript)

        // Polish done: fill the progress bar to 100% (with polish off it was already set to 1.0 above, idempotent here).
        if config.polishEnabled {
            updateProcessing(1.0, .polishing)
        }

        // 4) Inject at the target App's cursor (with a light hint on polish failure, but never losing characters).
        injectFinalText(polished.text, polishFailed: polished.failed)
    }

    // MARK: Polish

    /// The result of one polish step: the final text + whether it was a "failure fallback" (for an optional hint after injection).
    private struct PolishStep {
        let text: String
        /// true only means "the model was called but failed / Provider construction failed"; skip/off does not count as failure.
        let failed: Bool
    }

    /// Polishes per the config; both Provider construction failure / polish failure fall back to the original (never losing characters).
    private func polishIfEnabled(_ transcript: String) async -> PolishStep {
        guard config.polishEnabled else { return PolishStep(text: transcript, failed: false) }

        let provider: any LLMProvider
        do {
            provider = try await makePolishProvider()
        } catch {
            // No credentials / construction failure: use the original directly (not blocking injection), counted as failure for the optional hint.
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
        // Only .failedFallback counts as failure; .polished / .skipped do not hint.
        let failed: Bool
        if case .failedFallback = outcome.resolution { failed = true } else { failed = false }
        return PolishStep(text: outcome.text, failed: failed)
    }

    /// Builds the polish context with the current (or injection target) frontmost App info, to help the model judge register.
    private func polishContext() -> PolishContext {
        if let target = capturedTarget {
            return PolishContext(appName: target.localizedName, bundleId: target.bundleIdentifier)
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            return PolishContext(appName: app.localizedName, bundleId: app.bundleIdentifier)
        }
        return PolishContext()
    }

    /// Builds the polish ``LLMProvider`` per ``AppConfig/providerKind`` + credentials.
    /// Reuses the App-layer ``ProviderFactory``, with the credential account mapping consistent with the settings page.
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

    // MARK: Transcription timeout

    /// The marker error thrown when `transcribe(...)` exceeds ``transcribeTimeout`` without returning.
    private struct TranscribeTimeout: Error {}

    /// Wraps a piece of async transcription work with a hard timeout: whoever returns first wins, the other branch is cancelled.
    /// If the timeout branch arrives first, throws ``TranscribeTimeout`` (guaranteeing "never permanently stuck transcribing").
    /// - Parameter work: the actual transcription closure (returns ``TranscriptionResult``).
    private func withTranscribeTimeout(
        _ work: @escaping @Sendable () async throws -> TranscriptionResult
    ) async throws -> TranscriptionResult {
        let timeout = transcribeTimeout
        return try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TranscribeTimeout()
            }
            // Whoever returns first wins; then cancel the remaining branch (cancel the sleep branch or the still-running transcription branch).
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TranscribeTimeout()
            }
            return result
        }
    }

    // MARK: Transcriber construction / reuse / prewarm

    /// Returns the reused warm transcriber: when the current relevant config signature matches the cache, reuse the same instance (the local engine stays warm, no model reload);
    /// otherwise rebuild and cache via ``transcriberFactory``, while prewarming in the background (the local model's first frame is no longer slow).
    ///
    /// This is the core fix for "reloading the ~1GB model ~10s per dictation": the old logic produced a new instance via `transcriberFactory()` on each dictation,
    /// while ``WhisperKitTranscriber``'s engine is an **instance-level** cache, so a new instance necessarily lazily reloads the model. Reusing a single instance keeps it warm.
    private func currentTranscriber() throws -> any Transcriber {
        let signature = currentSignature()
        if let cachedTranscriber, cachedSignature == signature {
            return cachedTranscriber
        }
        let transcriber = try transcriberFactory()
        cachedTranscriber = transcriber
        cachedSignature = signature
        // A newly created one is prewarmed in the background (the local model triggers loading), not blocking the main thread, errors only logged.
        preloadInBackground(transcriber)
        return transcriber
    }

    /// The signature of the current relevant STT config. The cloud key is taken from the Keychain (missing recorded as an empty string), and a change triggers a rebuild.
    private func currentSignature() -> TranscriberSignature {
        let cloudKey = (KeychainStore.get(account: KeychainStore.Account.openAIAPIKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriberSignature(
            mode: config.sttMode,
            localModel: config.localModel,
            cloudModel: config.cloudSTTModel,
            cloudKey: cloudKey
        )
    }

    /// Background prewarm the transcriber: only meaningful for the local ``WhisperKitTranscriber`` (loading the CoreML engine).
    /// Does not block the UI; prewarm failure only logs (not affecting the lazy-load fallback during the real later dictation).
    private func preloadInBackground(_ transcriber: any Transcriber) {
        guard let whisper = transcriber as? WhisperKitTranscriber else { return }
        preloadTask?.cancel()
        preloadTask = Task.detached(priority: .utility) {
            do {
                try await whisper.preload()
            } catch {
                NSLog("[SayIt] 本地模型预热失败（将按需惰性加载）: %@", String(describing: error))
            }
        }
    }

    /// Opportunistic prewarming at launch: if currently in local mode and the model is downloaded, construct and prewarm the transcriber ahead of time,
    /// making the **first** dictation fast too. Construction failure (theoretically the local path will not) only logs, not affecting later on-demand construction.
    private func preloadLocalIfReady() {
        guard config.sttMode == .local else { return }
        guard ModelManager.isDownloaded(model: config.localModel) else { return }
        // Reuse currentTranscriber's cache + prewarm path, avoiding a duplicate instance.
        _ = try? currentTranscriber()
    }

    /// Chooses the transcriber per ``STTMode``. Local uses ``WhisperKitTranscriber``, cloud uses ``CloudTranscriber``.
    ///
    /// The cloud path **takes the OpenAI API key from ``KeychainStore`` and injects it into** ``CloudTranscriber`` (which itself does not read the Keychain,
    /// staying testable); a missing/blank key throws `.notReady`, converged to a HUD hint by the caller. `static` so the default factory closure can reference it.
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

    // MARK: Injection

    /// Injects the final text: on focus drift still injects into the current frontmost (the clipboard fallback guarantees no lost characters), the result drives the HUD.
    /// - Parameters:
    ///   - text: the text to inject.
    ///   - polishFailed: whether polish failed and fell back (only used for a light hint after successful injection, not affecting the injection itself).
    private func injectFinalText(_ text: String, polishFailed: Bool) {
        let drifted = focusDrifted()
        let result = injector.inject(text)

        switch result {
        case .success:
            if drifted {
                // Focus drifted but the paste still succeeded: give a brief neutral hint, informing it was pasted into the current window.
                showTransientInfo(String(localized: "hud.pastedToCurrentWindow",
                                         defaultValue: "Pasted to the current window"))
            } else if polishFailed {
                // Injection succeeded but polish failed and fell back to the original: a light hint (never losing characters, only informing).
                showTransientInfo(String(localized: "hud.injectedPolishFailed",
                                         defaultValue: "Inserted (polish failed, used original text)"))
            } else {
                panel.hide()
                phase = .idle
            }
        case .failedTextLeftInPasteboard:
            // The text is left in the clipboard, hinting the user to paste manually.
            let hint = drifted
                ? String(localized: "hud.driftedCopiedPasteManually",
                         defaultValue: "Focus changed — text copied, please paste manually")
                : String(localized: "hud.copiedPasteManually",
                         defaultValue: "Copied to clipboard, please paste manually")
            showTransientError(hint)
        }
    }

    /// Whether the injection target is no longer frontmost (focus drift). When there is no recorded target it is treated as no drift.
    private func focusDrifted() -> Bool {
        guard let captured = capturedTarget,
              let current = currentFrontmostTarget() else {
            return false
        }
        return captured.processIdentifier != current.processIdentifier
    }

    // MARK: State convergence utilities

    /// Pushes the processing progress (0...1) and current phase to the HUD (Typeless-style progress bar).
    /// Centralized in one place to keep the progress updates running through the pipeline compact and readable.
    private func updateProcessing(_ progress: Double, _ phase: RecordingState.ProcessingPhase) {
        panel.update(state: .processing(progress: progress, phase: phase))
    }

    /// Takes a snapshot of the current frontmost App.
    private func currentFrontmostTarget() -> InjectionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InjectionTarget(running: app)
    }

    /// Empty audio / empty transcription: the HUD briefly hints then returns to idle.
    private func emptyToIdle() {
        showTransientError(String(localized: "hud.didNotCatchThat", defaultValue: "Didn’t catch that, please try again"))
    }

    /// Local model not ready: the HUD briefly shows a "model still downloading / please switch to cloud" error hint then returns to idle, and does not enter transcription.
    /// The copy is the in-bundle localization of ``RecordingState/modelNotReadyMessage`` (en + zh-Hans).
    private func modelNotReadyToIdle() {
        // Use the .error state to carry the localized copy (no new enum case, avoiding disturbing RecordingPanelView's exhaustive switch).
        showTransientError(RecordingState.modelNotReadyMessage)
    }

    /// Failure convergence: the HUD briefly reports an error then returns to idle, and best-effort stops any still-running recording.
    private func failToIdle(message: String) {
        // Recording may still be in progress (e.g. a corner case of erroring immediately after start), best-effort stop it to release the device.
        isRecording = false
        stopLevelForwarding()
        Task { [recorder] in _ = try? await recorder.stop() }
        showTransientError(message)
    }

    /// Briefly shows an error on the HUD, then automatically hides and returns to idle.
    private func showTransientError(_ message: String) {
        showTransient(.error(message))
    }

    /// Briefly shows a neutral hint on the HUD (e.g. "pasted into the current window"), then automatically hides and returns to idle.
    private func showTransientInfo(_ message: String) {
        showTransient(.info(message))
    }

    /// Briefly shows a transient state (error / info) on the HUD, then automatically hides and returns to idle.
    private func showTransient(_ state: RecordingState) {
        phase = .idle
        panel.update(state: state)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self else { return }
            // If a new round has begun during this period (the HUD is in listening/transcribing), do not interrupt it.
            guard self.processingTask == nil, self.phase == .idle else { return }
            self.panel.hide()
        }
    }

    // MARK: Static mapping / copy

    /// ``InteractionMode`` -> ``HotkeyMode``.
    private static func hotkeyMode(for mode: InteractionMode) -> HotkeyMode {
        switch mode {
        case .singleTap: return .singleTapToggle
        case .hold:      return .holdToTalk
        }
    }

    /// The user-facing copy for recording start failure.
    private static func recordingFailureMessage(_ error: Error) -> String {
        if let audioError = error as? AudioRecordingError,
           case .microphonePermissionDenied = audioError {
            return String(localized: "hud.needMicrophone", defaultValue: "Microphone permission required")
        }
        return String(localized: "hud.cannotStartRecording", defaultValue: "Cannot start recording")
    }

    /// The user-facing copy for transcription failure.
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

    // MARK: Test support (test-only seams)
    //
    // The coordinator is driven by HotkeyManager's AsyncStream events; real events depend on NSEvent global monitoring, which cannot be
    // synthesized in unit tests. Here we expose internal entry points to directly drive the same private handlers, and await the internal tasks for determinism.

    /// Directly triggers one "start" and waits for the recording start to wrap up (equivalent to receiving a `.start` hotkey event).
    func _test_start() async {
        handleStart()
        await startTask?.value
    }

    /// Directly triggers one "stop" and waits for the whole pipeline (transcribe -> polish -> inject) to finish (equivalent to receiving a `.stop`).
    func _test_stop() async {
        handleStop()
        await processingTask?.value
    }

    /// Whether currently recorded as recording (for tests to assert race protection).
    var _test_isRecording: Bool { isRecording }

    /// Directly calls config sync (for tests to assert item 2's compare-before-write-back behavior).
    func _test_applyHotkeyConfig() { applyHotkeyConfig() }

    /// Exposes the hotkey manager (for tests to observe triggerKey/mode).
    var _test_hotkeyManager: HotkeyManager { hotkeyManager }
}
