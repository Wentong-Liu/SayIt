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
    /// User-dictionary store (Layer 3): its entries drive deterministic rewriting (exact case / spacing) after polish, before injection.
    /// Reuses the ``DictionaryStore`` actor from PR-1; injectable so tests can pass an empty dictionary backed by a temp directory to verify "zero behavior change".
    private let dictionaryStore: DictionaryStore
    /// The focused-element text reader (learn-from-edits Part B). Reads the focused field's current text right after an inject
    /// (to snapshot the baseline) and again after the user makes an in-place edit (to diff). Returns nil on secure/unreadable
    /// fields, in which case the feature degrades silently. Injectable so tests can drive arm/read-back without a live UI.
    private let axReader: FocusedTextReading
    /// The dismissible "add to dictionary?" suggestion prompt (learn-from-edits Part B). A SEPARATE clickable panel from the
    /// dictation HUD (which ignores mouse events). Injectable so tests can drive Accept/Dismiss deterministically.
    private let suggestionPanel: SuggestionPanelController
    /// The start/stop chime cue player. Fire-and-forget and non-blocking; gated by ``AppConfig/soundCuesEnabled``.
    private let soundCues: SoundCuePlaying
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

    /// The in-flight recorder `stop()` kicked off by ``cancel()`` (and ``failToIdle(message:)``). ``cancel()`` returns immediately and resets the
    /// HUD/phase to idle, but the AVAudioEngine teardown inside `recorder.stop()` is still running afterwards. The NEXT recording start
    /// (``handleStart()``) must `await` this pending stop BEFORE calling `recorder.start()`, otherwise the new start collides with the
    /// not-yet-finished stop (the recorder is still `recording`, the device still busy) and fails with `.alreadyRecording` or stalls.
    /// Awaiting it makes a fresh start reliable IMMEDIATELY after cancel. Cleared when the stop wraps up.
    private var pendingStopTask: Task<Void, Never>?

    /// Monotonic id stamped on each ``beginPendingStop()``. ``awaitPendingStop()`` uses it to clear ``pendingStopTask`` only when it has not
    /// been replaced by a newer stop while suspended (`Task` is not `Equatable`, so an id is the way to detect replacement).
    private var pendingStopGeneration = 0

    /// Whether recording has started successfully (set by the start Task after `recorder.start()` succeeds).
    private var isRecording = false

    /// The task forwarding recording levels to the HUD: **each recording session** consumes the current session's `recorder.levels`.
    /// Key: `recorder.levels` must be read only after `recorder.start()` succeeds, because `AudioRecorder`
    /// rebuilds a brand-new pair of single-consumer streams on each `start()` (see `LevelStreamHolder`); a stream captured once before start
    /// would be finished by `beginSession()`, causing the forwarding loop to spin idle, the HUD waveform to stay at 0, and the dots to go dead.
    /// This task is cancelled when recording stops, and the HUD waveform settles with the 0 produced by `stop()`.
    private var levelTask: Task<Void, Never>?

    /// The in-flight delayed-hide task for the current transient HUD message (error / info). Stored so only the LATEST
    /// transient owns ``RecordingPanelController/hide()``: ``showTransient(_:)`` cancels+replaces it, and ``cancel()`` /
    /// ``stop()`` cancel it so a stale ~1.6s sleeper can never hide a freshly-started session's HUD or run after teardown.
    private var transientTask: Task<Void, Never>?

    /// Whether monitoring has started (idempotency protection).
    private var isStarted = false

    // MARK: Learn-from-edits state (Part B; entirely gated behind config.learnFromEditsEnabled)

    /// A pending injection that the user may edit in place. Armed right after a successful inject (only when learn-from-edits
    /// is enabled AND the focused field's text was readable) and consulted on the next edit-key signal to decide whether to
    /// diff. Has a freshness window so a stale injection (the user moved on long ago) never triggers a suggestion.
    private struct InjectionRecord {
        /// The exact string SayIt injected (the diff baseline for ``LearnedEditDetector``).
        let injectedText: String
        /// When this record expires; after this instant the edit signal is ignored (treated as normal typing).
        let expiresAt: Date
    }

    /// The current pending injection record (learn-from-edits). `nil` means nothing is armed (the common case: feature off,
    /// or no recent inject). Replaced on each arm; cleared on suggestion resolution, teardown, and ESC cancel.
    private var injectionRecord: InjectionRecord?

    /// The in-flight debounce task started on an edit-key signal: it waits ``learnDebounce`` then re-reads + diffs. Cancelled
    /// and replaced on each new edit-key (so a burst of deletes collapses into one read), and cancelled on teardown / cancel.
    private var learnDebounceTask: Task<Void, Never>?

    /// How long an armed injection record stays fresh (learn-from-edits). After this the edit signal is ignored. Injectable
    /// so tests use a tiny/large value instead of waiting the production window. Defaults to ~8s (per the approved spike).
    private let learnFreshness: Duration

    /// The debounce applied between an edit-key signal and the AX read-back + diff (learn-from-edits). Collapses a burst of
    /// deletes into one read. Injectable so tests pass a tiny value. Defaults to ~700ms (per the approved spike).
    private let learnDebounce: Duration

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

    /// Cached cloud-key signature component, paired with the cheap (mode/model) components it was read for. Avoids a
    /// synchronous ``KeychainStore`` read on the @MainActor dictation hot path on EVERY dictation (a UI/HUD hitch under
    /// Keychain contention): ``currentSignature()`` reuses this cached key while the cheap components are unchanged, and
    /// only re-reads the Keychain when the cheap components actually differ (a mode/model switch — exactly when a
    /// transcriber rebuild is already required, so the read is rare). The prewarm path refreshes it OFF the main actor.
    private var cachedCloudKey: String?

    /// The cheap (mode/model) signature the ``cachedCloudKey`` was read against. When the current cheap signature matches
    /// this, the cached key is reused with no Keychain read; otherwise the key is re-read and this is updated.
    private var cachedCloudKeySignature: CheapSignature?

    /// A snapshot of the relevant STT config that decides whether the transcriber needs rebuilding. Contains only fields that change the transcriber's identity/behavior:
    /// `sttMode` (local/cloud), `localModel` (local model), `cloudModel` and `cloudKey` (cloud model and credentials).
    /// The language is always auto-detected and not part of the signature.
    private struct TranscriberSignature: Equatable {
        let mode: STTMode
        let localModel: String
        let cloudModel: String
        let cloudKey: String
    }

    /// The cheap, main-actor-readable part of the STT signature (everything except the cloud key, which lives in the
    /// Keychain). Used to decide whether the cached cloud key is still valid without touching the Keychain per dictation.
    private struct CheapSignature: Equatable {
        let mode: STTMode
        let localModel: String
        let cloudModel: String
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

    /// Reads the trimmed cloud STT API key (the ``KeychainStore`` `openAIAPIKey` account by default). Injectable so tests
    /// can drive the cloud-key signature component without the real Keychain AND assert the read is not done on the
    /// per-dictation hot path (see ``cachedCloudKey``). `@Sendable` so it can be called from the off-main-actor prewarm path.
    private let cloudKeyReader: @Sendable () -> String

    /// - Parameters:
    ///   - config: the application config; defaults to `.shared`.
    ///   - hotkeyManager: the hotkey manager; defaults to constructing per the current config.
    ///   - recorder: the recorder; defaults to ``AudioRecorder``.
    ///   - panel: the HUD controller; defaults to the shared instance.
    ///   - injector: the text injector; defaults to ``TextInjector``.
    ///   - dictionaryStore: the user-dictionary store (for Layer 3 rewriting); defaults to ``DictionaryStore``, tests can pass an empty dictionary backed by a temp directory.
    ///   - transcriberFactory: the transcriber factory; defaults to choosing local/cloud per the config (see ``makeConfiguredTranscriber(_:)``).
    ///   - accessibilityGate: the accessibility gate; defaults to guiding authorization on demand (see ``ensureAccessibilityOrGuide()``).
    ///   - modelReadiness: local model readiness detection; defaults to read-only reuse of ``ModelManager/isDownloaded(model:)``.
    ///   - transcribeTimeout: the transcription hard timeout; defaults to 90s.
    ///   - soundCues: the start/stop chime player; defaults to the real ``SoundCuePlayer``. Tests can inject a no-op double.
    ///   - cloudKeyReader: reads the trimmed cloud STT API key; defaults to the ``KeychainStore`` `openAIAPIKey` account. Tests can inject it to drive the cloud-key signature and assert it is not read per dictation.
    ///   - axReader: the focused-element text reader for learn-from-edits; defaults to ``AXTextReader``. Tests inject a stub.
    ///   - suggestionPanel: the "add to dictionary?" prompt controller; defaults to the shared instance. Tests inject a fresh one.
    ///   - learnFreshness: how long an armed injection record stays fresh; defaults to ~8s. Tests pass a tiny/large value.
    ///   - learnDebounce: the edit-key -> read-back debounce; defaults to ~700ms. Tests pass a tiny value.
    init(config: AppConfig = .shared,
         hotkeyManager: HotkeyManager? = nil,
         recorder: AudioRecording = AudioRecorder(),
         panel: RecordingPanelController = .shared,
         injector: TextInjecting = TextInjector(),
         dictionaryStore: DictionaryStore = DictionaryStore(),
         transcriberFactory: (() throws -> any Transcriber)? = nil,
         accessibilityGate: (() -> Bool)? = nil,
         modelReadiness: ((String) -> Bool)? = nil,
         transcribeTimeout: Duration = .seconds(90),
         soundCues: SoundCuePlaying = SoundCuePlayer(),
         cloudKeyReader: (@Sendable () -> String)? = nil,
         axReader: FocusedTextReading = AXTextReader(),
         suggestionPanel: SuggestionPanelController = .shared,
         learnFreshness: Duration = .seconds(8),
         learnDebounce: Duration = .milliseconds(700)) {
        self.config = config
        self.recorder = recorder
        self.panel = panel
        self.injector = injector
        self.dictionaryStore = dictionaryStore
        self.axReader = axReader
        self.suggestionPanel = suggestionPanel
        self.learnFreshness = learnFreshness
        self.learnDebounce = learnDebounce
        self.soundCues = soundCues
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
        // The default reader trims the openAIAPIKey from the Keychain (matching makeConfiguredTranscriber / the old currentSignature).
        self.cloudKeyReader = cloudKeyReader ?? {
            (KeychainStore.get(account: KeychainStore.Account.openAIAPIKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
                // Refresh the cached cloud key off the main actor so a mode/model change (the observable cloud-config
                // change) keeps the warm path's key current without a per-dictation synchronous Keychain read.
                self?.refreshCloudKeyInBackground()
            }
        }

        applyHotkeyConfig()
        // ESC-to-cancel wiring: the manager fires onCancel only while a dictation session is active (phase != .idle), so ESC is never swallowed when idle.
        hotkeyManager.isSessionActive = { [weak self] in (self?.phase ?? .idle) != .idle }
        hotkeyManager.onCancel = { [weak self] in self?.cancel() }
        // Learn-from-edits: a passive Backspace / Forward-Delete signal. handleEditKey is a no-op unless a fresh injection
        // record exists (which is itself only armed when learnFromEditsEnabled), so wiring this is harmless when the feature is off.
        hotkeyManager.onEditKey = { [weak self] in self?.handleEditKey() }
        startEventLoop()
        hotkeyManager.start()
        phase = .idle

        // Start opportunistic prewarming: in local mode with the model already downloaded, load ahead of time so the first dictation is not slow either (not blocking the main thread).
        preloadLocalIfReady()
        // Warm the cached cloud key off the main actor at launch so the first cloud dictation does not block on a synchronous Keychain read.
        refreshCloudKeyInBackground()
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
        pendingStopTask?.cancel()
        pendingStopTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        // Teardown cancels an in-flight ~1.6s transient sleeper so it cannot run panel.hide() after stop().
        transientTask?.cancel()
        transientTask = nil
        // Learn-from-edits teardown: drop any armed record + in-flight debounce + visible suggestion so a stale
        // record/suggestion never survives teardown (and a late debounce can never fire a read after stop()).
        clearLearnFromEdits()
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

    /// Plays a dictation chime cue if the user has them enabled. The single place both the start and stop hooks gate on
    /// ``AppConfig/soundCuesEnabled`` (read live, so flipping the setting takes effect on the next dictation).
    /// Fire-and-forget and non-blocking (see ``SoundCuePlayer``), so it never stalls the recording pipeline.
    private func playCueIfEnabled(_ cue: SoundCue) {
        guard config.soundCuesEnabled else { return }
        soundCues.play(cue)
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
        // Recording has begun (guards + accessibility gate passed): fire the ascending start chime for immediate feedback.
        playCueIfEnabled(.start)

        startTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }
            do {
                // Wait out any in-flight recorder stop from a just-cancelled session (ESC) before starting a new one. Without this the
                // new start races the cancel's not-yet-finished AVAudioEngine teardown: the recorder is still `recording` / the device
                // still busy, so recorder.start() throws `.alreadyRecording` or stalls — the exact "can't restart right after ESC" bug.
                await self.awaitPendingStop()
                // Cancellation guard #1: an ESC cancel can land while suspended in awaitPendingStop(). awaitPendingStop()
                // does NOT throw on cancel, so without this guard the closure would proceed to start the recorder and
                // resurrect the session AFTER cancel() already reset phase to .idle. cancel() already cleared state and
                // released the device; nothing started yet here, so just bail.
                guard !Task.isCancelled else { return }
                // Start recording with the persisted input device: read config.inputDeviceUID fresh on each press,
                // letting the microphone selected in the settings page take effect immediately for the next dictation (no App restart needed).
                // nil = follow the system default (equivalent to start()); when the UID is invalid, AudioRecorder automatically falls back to the system default.
                try await self.recorder.start(deviceUID: self.config.inputDeviceUID)
                // Cancellation guard #2: an ESC cancel can land while suspended in recorder.start(). recorder.start() does
                // NOT throw on cancel, so without this guard the closure would set isRecording=true + start level forwarding
                // while phase is already .idle — a resurrected, unstoppable session whose device is left open. Since
                // start() already succeeded here, release the device via the same pending-stop path cancel() uses, so the
                // next start awaits it before recorder.start() (no .alreadyRecording race). Do NOT mark recording / forward levels.
                guard !Task.isCancelled else {
                    self.beginPendingStop()
                    return
                }
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

    /// ESC during an in-progress dictation: abort recording + the in-flight transcribe/polish/inject Task, reset the HUD to idle, inject nothing.
    /// No-op when already idle (ESC is ignored upstream by ``HotkeyManager`` when no session is active, but guard here too for direct callers/tests).
    func cancel() {
        guard phase != .idle else { return }
        // Cancel the in-flight pipeline (transcribe/polish/inject). runPipeline early-returns at its `Task.isCancelled` guards and injects nothing;
        // a cancel mid-transcribe surfaces as CancellationError, swallowed silently (no HUD error flash). Clear the handle now so re-entry guards see "no active processing".
        processingTask?.cancel()
        processingTask = nil
        // Cancel a still-pending recording start (extremely-short-press race), so its completion cannot resurrect the session.
        startTask?.cancel()
        startTask = nil
        // Cancel any in-flight transient delayed-hide so a stale ~1.6s sleeper cannot hide this freshly-started session's HUD.
        transientTask?.cancel()
        transientTask = nil
        // Stop level forwarding and best-effort stop the recorder to release the device (same pattern as failToIdle).
        isRecording = false
        stopLevelForwarding()
        // Track this best-effort stop so the NEXT start awaits it before recorder.start() — otherwise the new start races the
        // not-yet-finished engine teardown and fails with `.alreadyRecording`/stalls (the "can't restart right after ESC" bug).
        beginPendingStop()
        // Resync the single-tap-toggle state machine: this session is ending WITHOUT a second tap, so its `isActive` toggle
        // (the sole start/stop driver) must be forced back to inactive — otherwise the user's NEXT tap would emit a phantom
        // `.stop` against the now-idle coordinator and be silently wasted (forcing a double tap to resume). Hold mode is unaffected.
        hotkeyManager.sessionDidEndExternally()
        // Learn-from-edits: an ESC cancel ends the session — drop any armed record / in-flight debounce / visible suggestion
        // so a stale record from a prior inject can never trigger a suggestion after the user cancelled.
        clearLearnFromEdits()
        // Reset the HUD to idle. Inject NOTHING.
        panel.hide()
        phase = .idle
    }

    /// Best-effort stops the recorder in a stored ``pendingStopTask`` (instead of a fire-and-forget detached Task), so a subsequent
    /// ``handleStart()`` can `await` it via ``awaitPendingStop()`` before `recorder.start()`. Replacing any prior pending stop is safe:
    /// only one recorder exists and `stop()` is idempotent on the actor; the most recent stop is the one a later start must wait out.
    private func beginPendingStop() {
        pendingStopGeneration += 1
        let generation = pendingStopGeneration
        pendingStopTask = Task { [recorder] in
            _ = try? await recorder.stop()
            // Self-clear once done, but only if no newer stop has superseded this one (so a later start does not await an already-finished stop).
            await MainActor.run { [weak self] in
                guard let self, self.pendingStopGeneration == generation else { return }
                self.pendingStopTask = nil
            }
        }
    }

    /// Awaits any in-flight stop kicked off by ``cancel()`` / ``failToIdle(message:)``, so the recorder's teardown is fully finished before the
    /// caller starts a new recording. No-op when there is no pending stop. Clears the handle only if it was not superseded while suspended.
    private func awaitPendingStop() async {
        guard let pending = pendingStopTask else { return }
        let generation = pendingStopGeneration
        await pending.value
        if pendingStopGeneration == generation {
            pendingStopTask = nil
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
            // Recording actually stopped (success branch only, no double-cue on stop failure): fire the descending stop chime.
            playCueIfEnabled(.stop)
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
        // ONE consistent dictionary snapshot per utterance: read the store a single time here and thread the SAME
        // `entries` through transcribe biasing (Layer 1), polish glossary (Layer 2), and deterministic rewriting
        // (Layer 3). This guarantees all three layers see the same dictionary even if the user edits it mid-pipeline,
        // and collapses three actor reads into one. An empty dictionary -> [] everywhere (byte-identical no-op).
        let entries = await dictionaryStore.all()

        let transcript: String
        do {
            let transcriber = try currentTranscriber()
            // User-dictionary Layer 1 biasing: order the enabled entries' canonical terms by usageCount ascending
            // (most-used LAST, see GlossaryPrompt) and pass them as biasing options so STT is steered toward the user's
            // dictionary words (best-effort recall boost). Ordering happens HERE, at the single source, so the documented
            // usageCount ordering actually reaches the transcriber and the token-cap suffix keeps the highest-usage terms.
            // An empty dictionary -> empty terms -> no prompt is built anywhere (byte-identical to before this feature).
            let biasTerms = GlossaryPrompt.orderedCanonicals(from: entries)
            // Speech recognition always auto-detects the language (T24): always passes nil to let the backend judge by the speech, no longer reading AppConfig.language.
            let result = try await withTranscribeTimeout {
                try await transcriber.transcribe(
                    samples,
                    sampleRate: AudioFormat.sampleRate,
                    language: nil,
                    options: TranscribeOptions(biasTerms: biasTerms)
                )
            }
            transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            // ESC cancelled the dictation mid-transcribe: abort silently (the user intentionally aborted), no HUD error flash, inject nothing.
            // withTranscribeTimeout's child tasks inherit cancellation, so an outer cancel makes the inner transcribe/Task.sleep throw CancellationError that surfaces here.
            return
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

        // ESC cancel during transcribe: a transcriber that returns a value without throwing on cancel (e.g. FakeTranscriber) lands here.
        // Early-return discards the result and injects nothing; the defer clears processingTask.
        guard !Task.isCancelled else { return }

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
        //    Threads the same per-utterance `entries` snapshot so the polish glossary (Layer 2) sees the same dictionary.
        let polished = await polishIfEnabled(transcript, entries: entries)

        // ESC cancel during polish: discard the polished result and inject nothing.
        guard !Task.isCancelled else { return }

        // Polish done: fill the progress bar to 100% (with polish off it was already set to 1.0 above, idempotent here).
        if config.polishEnabled {
            updateProcessing(1.0, .polishing)
        }

        // 3.5) User-dictionary Layer 3: deterministic rewriting (exact case / spacing) after polish, before injection.
        //      Reuses the same per-utterance `entries` snapshot (no extra actor read). An empty dictionary is identity (zero behavior change).
        let finalText = DictionaryRewriter.apply(to: polished.text, using: entries)

        // Load-bearing cancel guard: even if transcribe + polish + dictionary all completed, an ESC cancel before this line means injectFinalText is never reached — no text is injected.
        guard !Task.isCancelled else { return }

        // 4) Inject at the target App's cursor (with a light hint on polish failure, but never losing characters).
        injectFinalText(finalText, polishFailed: polished.failed)
    }

    // MARK: Polish

    /// The result of one polish step: the final text + whether it was a "failure fallback" (for an optional hint after injection).
    private struct PolishStep {
        let text: String
        /// true only means "the model was called but failed / Provider construction failed"; skip/off does not count as failure.
        let failed: Bool
    }

    /// Polishes per the config; both Provider construction failure / polish failure fall back to the original (never losing characters).
    /// - Parameter entries: the per-utterance dictionary snapshot (shared with Layer 1/3), used to build the Layer 2 glossary.
    private func polishIfEnabled(_ transcript: String, entries: [DictionaryEntry]) async -> PolishStep {
        guard config.polishEnabled else { return PolishStep(text: transcript, failed: false) }

        let provider: any LLMProvider
        do {
            provider = try await makePolishProvider()
        } catch {
            // No credentials / construction failure: use the original directly (not blocking injection), counted as failure for the optional hint.
            NSLog("[SayIt] 润色 Provider 构造失败，回退原文: %@", String(describing: error))
            return PolishStep(text: transcript, failed: true)
        }

        // User-dictionary Layer 2: feed a relevant subset of dictionary terms into the polish system prompt so the
        // model spells canonical forms in context. An empty dictionary / no candidates yields an empty subset, which
        // keeps the prompt byte-identical to today (zero behavior change). Uses the same per-utterance `entries`
        // snapshot threaded in from runPipeline (no extra actor read; consistent with Layer 1/3).
        let glossary = DictionaryGlossary.relevantSubset(for: transcript, entries: entries)

        let outcome = await polishPipeline.polish(
            transcript,
            context: polishContext(),
            style: config.polishStyle,
            provider: provider,
            polishEnabled: true,
            glossary: glossary
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
    ///
    /// To keep the per-dictation @MainActor path free of a synchronous ``KeychainStore`` read (a UI/HUD hitch under
    /// Keychain contention), the cloud key is cached against the cheap (mode/model) components and re-read ONLY when those
    /// change — i.e. exactly when a transcriber rebuild is already required, so a Keychain switch is rare. The prewarm
    /// path refreshes the cached key OFF the main actor (see ``refreshCloudKeyInBackground()``) so the warm path stays current.
    ///
    /// Key-only re-save: `SettingsViewModel.saveCloudSTTAPIKey()` now posts `AppConfig.didChangeNotification`
    /// (via `AppConfig.notifyExternalChange()`) on a successful Keychain write, so the observer above runs
    /// ``refreshCloudKeyInBackground()`` to re-read the new key. A key-only re-save with the SAME model is therefore
    /// observed on the next dictation, without an unrelated config change / prewarm / app cycle.
    private func currentSignature() -> TranscriberSignature {
        let cheap = CheapSignature(
            mode: config.sttMode,
            localModel: config.localModel,
            cloudModel: config.cloudSTTModel
        )
        return TranscriberSignature(
            mode: cheap.mode,
            localModel: cheap.localModel,
            cloudModel: cheap.cloudModel,
            cloudKey: cloudKey(for: cheap)
        )
    }

    /// Returns the cloud key for the given cheap signature, reusing the cached value when the cheap components are
    /// unchanged (no Keychain read on the hot path) and re-reading via ``cloudKeyReader`` only when they differ.
    private func cloudKey(for cheap: CheapSignature) -> String {
        if let cachedCloudKey, cachedCloudKeySignature == cheap {
            return cachedCloudKey
        }
        let key = cloudKeyReader()
        cachedCloudKey = key
        cachedCloudKeySignature = cheap
        return key
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

    /// Refreshes the cached cloud key OFF the main actor (Task.detached), so the per-dictation hot path never blocks on a
    /// synchronous Keychain read while still picking up a freshly-saved key. Called from the launch/config-change prewarm
    /// path. The cheap signature this key belongs to is captured on the main actor before the detached read.
    private func refreshCloudKeyInBackground() {
        let cheap = CheapSignature(
            mode: config.sttMode,
            localModel: config.localModel,
            cloudModel: config.cloudSTTModel
        )
        let reader = cloudKeyReader
        Task.detached(priority: .utility) {
            let key = reader()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cachedCloudKey = key
                self.cachedCloudKeySignature = cheap
            }
        }
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
            // Learn-from-edits ARM: only on a clean, non-drifted success (the focus target did not move, so the just-injected
            // text is what the focused field now holds). Drift means the paste landed elsewhere, so there is nothing reliable
            // to diff later — skip arming there. Gated + no-op internally when the feature is off (see armLearnFromEditsIfEnabled).
            if !drifted {
                armLearnFromEditsIfEnabled(injected: text)
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

    // MARK: Learn from edits (Part B)
    //
    // The whole feature is gated behind config.learnFromEditsEnabled (default OFF): when OFF nothing is armed, the edit-key
    // handler is a no-op, and no AX read ever happens — ZERO behavior change. Flow: ARM after a successful inject -> the user
    // edits in place (a Backspace/Forward-Delete fires onEditKey) -> debounce -> re-read the focused field -> diff against the
    // injected baseline (LearnedEditDetector) -> if a single-token proper-noun substitution is found, SUGGEST adding it.

    /// ARM: snapshot the just-injected text as a diff baseline, but ONLY when learn-from-edits is enabled AND the focused
    /// field's text is currently readable (we cannot diff what we cannot read — secure/web/terminal fields return nil here).
    /// Replaces any prior record (the latest inject is the only one worth learning from) and sets a freshness expiry.
    private func armLearnFromEditsIfEnabled(injected: String) {
        guard config.learnFromEditsEnabled else { return }
        // Drop any prior debounce/suggestion: a new inject supersedes an older pending one.
        learnDebounceTask?.cancel()
        learnDebounceTask = nil
        // Read the focused field right after the paste landed. nil (secure/unreadable) -> do not arm (can't diff later).
        guard axReader.readFocusedText() != nil else {
            injectionRecord = nil
            return
        }
        injectionRecord = InjectionRecord(injectedText: injected,
                                          expiresAt: Date().addingTimeInterval(learnFreshness.timeIntervalValue))
    }

    /// TRIGGER (edit key): called on a Backspace / Forward-Delete signal. A no-op unless a FRESH injection record exists —
    /// so it never interferes with normal typing/deleting. Starts/restarts a short debounce so a burst of deletes collapses
    /// into a single read-back + diff.
    private func handleEditKey() {
        // Gate first: when the feature is off nothing was ever armed, so this is already a no-op, but guard explicitly so a
        // stray record (e.g. toggled off mid-window) is also ignored and cleared.
        guard config.learnFromEditsEnabled else {
            clearLearnFromEdits()
            return
        }
        guard let record = injectionRecord else { return }    // nothing armed -> normal typing, ignore.
        guard record.expiresAt > Date() else {                // stale -> drop and ignore (never interfere with typing).
            clearLearnFromEdits()
            return
        }

        // Debounce: cancel+replace the pending read so a run of edit keys results in one read after the user pauses.
        learnDebounceTask?.cancel()
        learnDebounceTask = Task { [weak self, learnDebounce] in
            try? await Task.sleep(for: learnDebounce)
            if Task.isCancelled { return }
            guard let self else { return }
            self.runLearnReadBackAndDiff()
        }
    }

    /// DEBOUNCE fire -> READ + DIFF: re-read the focused field and diff against the injected baseline. Silently drops the
    /// suggestion on any of: record cleared/expired while debouncing, AX read returns nil (focus moved to a secure/unreadable
    /// field), or the detector finds no learnable single-token substitution. Otherwise presents the suggestion.
    private func runLearnReadBackAndDiff() {
        guard config.learnFromEditsEnabled else { return }
        guard let record = injectionRecord, record.expiresAt > Date() else {
            clearLearnFromEdits()
            return
        }
        // Re-read the current focused text. nil -> the field is no longer readable (moved away / secure) -> drop silently.
        guard let current = axReader.readFocusedText() else { return }
        guard let suggestion = LearnedEditDetector.suggestion(injected: record.injectedText, edited: current.value) else {
            return    // no learnable single-token proper-noun substitution -> drop silently.
        }
        presentSuggestion(heard: suggestion.heard, corrected: suggestion.corrected)
    }

    /// SUGGEST: show the dismissible "Add \"corrected\" to dictionary?" prompt. On Accept -> persist a `.learnedFromEdit`
    /// entry and clear the record; on Dismiss / auto-expire -> just clear the record. Never auto-adds.
    private func presentSuggestion(heard: String, corrected: String) {
        suggestionPanel.show(
            corrected: corrected,
            heard: heard,
            onAccept: { [weak self] in
                guard let self else { return }
                // Persist off the main actor (DictionaryStore is an actor); then drop the record so it cannot re-trigger.
                Task { await self.dictionaryStore.add(
                    DictionaryEntry(canonical: corrected, variants: [heard], source: .learnedFromEdit)) }
                self.injectionRecord = nil
            },
            onDismiss: { [weak self] in
                // Dismiss / auto-expire: never add; just drop the record.
                self?.injectionRecord = nil
            }
        )
    }

    /// Clears all learn-from-edits transient state: the armed record, the in-flight debounce, and any visible suggestion.
    /// Called on teardown (``stop()``), ESC cancel (``cancel()``), and when the feature is observed off mid-window.
    private func clearLearnFromEdits() {
        injectionRecord = nil
        learnDebounceTask?.cancel()
        learnDebounceTask = nil
        suggestionPanel.hide()
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
        // Capture whether the recorder may still be live BEFORE clearing the flag. Most failToIdle paths fire AFTER
        // runPipeline already ran a successful recorder.stop() (transcribe timeout/failure, empty transcript), so the
        // recorder is already `.notRecording`: a second beginPendingStop() there is a swallowed no-op that also leaves a
        // misleading pendingStopTask the next handleStart needlessly awaits. Only stop the recorder when it might still
        // be running (the "error immediately after start" corner, where isRecording is still true).
        let wasRecording = isRecording
        isRecording = false
        stopLevelForwarding()
        if wasRecording {
            // Track this best-effort stop (same reasoning as cancel()): a restart immediately after a failure must await the teardown before recorder.start().
            beginPendingStop()
        }
        // Resync the single-tap-toggle state machine. The load-bearing case is a recording START-failure (e.g. microphone
        // denied): the first tap already flipped `isActive` true, but recording never began, so without this the user's NEXT
        // tap emits a phantom `.stop` and is wasted. The post-stop-tap failure paths (transcribe timeout/failure) reach here
        // with `isActive` already inactive, so this is a harmless no-op there. Hold mode is unaffected. (Same call as cancel().)
        hotkeyManager.sessionDidEndExternally()
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
        // Cancel+replace any prior in-flight delayed-hide so only the LATEST transient owns panel.hide().
        transientTask?.cancel()
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            // Cancelled (superseded by a newer transient, or torn down by cancel()/stop()): do not touch the HUD.
            if Task.isCancelled { return }
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

    /// Directly triggers one "start" but does NOT await the start Task (so a test can interleave releasing a gated cancel-stop while the
    /// restart is mid-flight). Pair with ``_test_awaitStart()``.
    func _test_handleStart() { handleStart() }

    /// Awaits the in-flight start Task's completion (no-op if none).
    func _test_awaitStart() async { await startTask?.value }

    /// The current in-flight start Task handle, captured for a test to `await` AFTER ``cancel()`` has nilled out
    /// ``startTask`` — letting the test deterministically wait for the cancelled (orphaned) start closure to fully run
    /// its `Task.isCancelled` guard / pending-stop path, so the no-resurrection assertions are not racy.
    var _test_startTask: Task<Void, Never>? { startTask }

    /// Directly triggers one "stop" and waits for the whole pipeline (transcribe -> polish -> inject) to finish (equivalent to receiving a `.stop`).
    func _test_stop() async {
        handleStop()
        await processingTask?.value
    }

    /// Directly triggers one "stop" but does NOT await the pipeline (so a test can interleave a `_test_cancel()` mid-flight). Pair with ``_test_awaitProcessing()``.
    func _test_handleStop() { handleStop() }

    /// Awaits the in-flight processing task's completion (no-op if none). Lets a test deterministically wait for the pipeline's early-return after a cancel.
    func _test_awaitProcessing() async { await processingTask?.value }

    /// Directly triggers a cancel (equivalent to ESC during an active session). For tests.
    func _test_cancel() { cancel() }

    /// Whether currently recorded as recording (for tests to assert race protection).
    var _test_isRecording: Bool { isRecording }

    /// Directly calls config sync (for tests to assert item 2's compare-before-write-back behavior).
    func _test_applyHotkeyConfig() { applyHotkeyConfig() }

    /// Exposes the hotkey manager (for tests to observe triggerKey/mode).
    var _test_hotkeyManager: HotkeyManager { hotkeyManager }

    /// Directly shows a transient error HUD message (starts the delayed-hide ``transientTask``). For tests asserting transient-task cancellation.
    func _test_showTransientError(_ message: String) { showTransientError(message) }

    /// Whether a transient delayed-hide task currently exists and is cancelled. Lets a test assert that ``cancel()`` /
    /// ``stop()`` cancelled the in-flight ~1.6s sleeper (so a stale transient can never hide a fresh session / run after teardown).
    var _test_transientTaskCancelled: Bool { transientTask?.isCancelled ?? false }

    /// Whether a transient delayed-hide task currently exists (cancelled or not). For tests to assert showTransient started one.
    var _test_hasTransientTask: Bool { transientTask != nil }

    /// Exposes the current transient delayed-hide task handle, so a test can capture it BEFORE ``cancel()`` / ``stop()``
    /// nils it out and then assert the captured handle was cancelled (teardown cancelled the in-flight sleeper).
    var _test_transientTask: Task<Void, Never>? { transientTask }

    /// Whether a recorder stop is currently pending (``beginPendingStop()`` ran and has not yet self-cleared). Lets a test
    /// assert the failToIdle guard did NOT leave a misleading pendingStop on the already-stopped path.
    var _test_hasPendingStop: Bool { pendingStopTask != nil }

    /// Whether a level-forwarding task currently exists (cancelled or not). Lets a test assert that a cancel landing
    /// mid-start did NOT resurrect the session by starting level forwarding after the phase was already reset to idle.
    var _test_hasLevelTask: Bool { levelTask != nil }

    // MARK: Test support — learn from edits

    /// Whether an injection record is currently armed (learn-from-edits). Lets a test assert ARM happened (toggle ON) or did
    /// NOT happen (toggle OFF / AX nil), without exposing the private record's contents.
    var _test_injectionRecordArmed: Bool { injectionRecord != nil }

    /// Force-arms a learn-from-edits injection record with a custom expiry, bypassing the AX read at arm time. Lets a test
    /// exercise the expired-record path deterministically (pass a past `expiresAt`) without waiting the real freshness window.
    func _test_armInjectionRecord(injected: String, expiresAt: Date) {
        injectionRecord = InjectionRecord(injectedText: injected, expiresAt: expiresAt)
    }

    /// Directly drives the edit-key handler (equivalent to a Backspace/Forward-Delete signal), then awaits the debounce
    /// read-back so the test is deterministic. No-op if the handler started no debounce (gated off / no fresh record).
    func _test_handleEditKey() async {
        handleEditKey()
        await learnDebounceTask?.value
    }

    /// Exposes the suggestion panel so a test can drive Accept/Dismiss and assert visibility deterministically.
    var _test_suggestionPanel: SuggestionPanelController { suggestionPanel }
}

/// Converts a `Duration` to a `TimeInterval` (seconds) for `Date` arithmetic. `Duration.components` yields whole seconds +
/// attoseconds (1e-18); both are summed so sub-second debounce/freshness values survive the conversion.
private extension Duration {
    var timeIntervalValue: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
