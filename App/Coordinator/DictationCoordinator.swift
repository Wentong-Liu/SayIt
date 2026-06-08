import AppKit
import os
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
    /// (to confirm the field is readable + arm) and again when editing is DONE (to send the final text to the extractor).
    /// Returns nil on secure/unreadable fields, in which case the feature degrades silently. Injectable so tests can drive
    /// arm/compare without a live UI.
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

    // MARK: Learn-from-edits state (Part B v2; always on — no opt-in)

    /// A pending injection that the user may edit in place. Armed right after a successful, non-drifted inject (when the
    /// focused field's text was readable). The compare fires when editing is DONE — on commit (Return/keypad-Enter), focus
    /// loss (app deactivation), ~idle of keystrokes, or a new dictation — whichever happens FIRST, exactly ONCE. Has a
    /// generous freshness window (until the next dictation OR ~120s) since the user may edit for a while before committing.
    private struct InjectionRecord {
        /// The exact string SayIt injected (the baseline sent to the term extractor as `injected`).
        let injectedText: String
        /// When this record expires; after this instant a compare trigger is ignored (the user moved on long ago).
        let expiresAt: Date
        /// When this record was armed (diagnostic / future tuning).
        let armedAt: Date
        /// The process id of the focused app at arm time (a lightweight focus identity to detect "armed field lost focus").
        let targetPID: pid_t?
    }

    /// The current pending injection record (learn-from-edits). `nil` means nothing is armed (the common case: no recent
    /// inject). Replaced on each arm; cleared on the first compare trigger, suggestion resolution, teardown, ESC cancel,
    /// and at the start of a new dictation. Clearing it makes any later trigger for the same inject a no-op (compare runs once).
    private var injectionRecord: InjectionRecord?

    /// Whether the user has actually EDITED (pressed Backspace / Forward-Delete) since the current record was armed. A real
    /// correction must involve a delete, so this is the necessary signal that an edit happened; the commit / focus-loss /
    /// idle triggers only decide WHEN to compare. Reset to false on each arm; set true by ``handleEditKey()`` while armed.
    /// ``fireCompare()`` drops without reading AX / calling the LLM when this is still false. (A stale value can never cause
    /// a spurious compare: a re-arm resets it, and `fireCompare`'s `guard let record` short-circuits when nothing is armed.)
    private var didEdit = false

    /// The in-flight idle timer: started on arm and reset (cancel + reschedule) on every keystroke while armed; when it
    /// fires (the user paused ~`idleAfter`) the compare runs. Cancelled on teardown / cancel / first compare / next dictation.
    private var idleTimerTask: Task<Void, Never>?

    /// The in-flight term-extraction LLM task. Cancelled on teardown / cancel / next dictation so an in-flight extraction
    /// never outlives the session and never fires a suggestion after stop.
    private var extractTask: Task<Void, Never>?

    /// The focus-loss observer token (NSWorkspace didDeactivateApplicationNotification). Registered in ``start()``,
    /// removed in ``stop()`` — when the armed app deactivates (the user clicked away / switched apps) the edit is treated
    /// as committed and the compare fires once.
    private var focusLossObserver: NSObjectProtocol?

    /// How long an armed injection record stays fresh (learn-from-edits). After this a compare trigger is ignored.
    /// Injectable so tests use a tiny/large value instead of waiting the production window. Defaults to ~120s (the user may
    /// edit for a while before committing; a new dictation also drops the record regardless).
    private let learnFreshness: Duration

    /// How long after the LAST keystroke (while armed) the idle compare fires. Reset on every keystroke. Injectable so
    /// tests pass a tiny value. Defaults to ~3s.
    private let learnIdleAfter: Duration

    /// Diagnostics-only logger for the learn-from-edits v2 flow (observability, no behavior). `.notice`/`.error` level so
    /// lines are visible in `log stream --predicate 'subsystem == "com.liuwentong.SayIt"'`; reuses the existing subsystem
    /// with a dedicated `learn` category. `static` so it is reachable from the idle-timer / extract `Task` closures without
    /// actor-isolation or capture friction. Text values are interpolated with `privacy: .public` (the user's own machine,
    /// actively debugging) so they appear unredacted.
    private nonisolated static let log = Logger(subsystem: "com.liuwentong.SayIt", category: "learn")

    /// End-to-end pipeline metrics logger (observability only, no behavior). Emits ONE `.notice` key=value summary per
    /// COMPLETED dictation (one that reached injection) so the dev can see where the stop -> transcribe -> dict -> polish ->
    /// inject latency goes and target optimizations. Reuses the existing subsystem with a dedicated `metrics` category; the
    /// higher-level sibling of the #63 `stt` line (which measures pure WhisperKit inference) — both are retained. Only
    /// numbers are logged (`privacy: .public`); the transcribed/injected TEXT is never interpolated, only its char count.
    /// `static` so it is reachable without actor-isolation friction (mirrors the `learn` logger above).
    private nonisolated static let metricsLog = Logger(subsystem: "com.liuwentong.SayIt", category: "metrics")

    /// The injected override for building the term-extraction provider (learn-from-edits Part C). `nil` (production
    /// default) means reuse ``makePolishProvider()`` exactly (same provider/model/key path as polish) — see
    /// ``buildLearnProvider()``. If no provider/key is configured the build throws and the compare drops silently (feature
    /// inactive). Tests inject one that returns a dummy provider deterministically (or throws to exercise the no-provider
    /// drop) without touching the real Keychain.
    private let learnProviderFactoryOverride: (() async throws -> any LLMProvider)?

    /// Builds the term extractor for a given provider (learn-from-edits Part C). Defaults to a real
    /// ``LearnedTermExtractor`` backed by the constructed provider; tests inject a fake returning a chosen result / nil.
    private let termExtractorFactory: (any LLMProvider) -> any LearnedTermExtracting

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

    /// Reads the current ``ModelManager/State`` to produce truthful not-ready copy: distinguishes "downloading NN%" from
    /// "no model yet" (which the boolean ``modelReadiness`` alone cannot express). By default read-only reuses the
    /// process-shared ``ModelManager/shared``'s published `state` (no network, no download — main-actor read, same as the
    /// menu-bar status line); tests inject a constant `.downloading(...)`/`.notDownloaded`/`.failed` to drive the
    /// state-aware message without the singleton/network. **Read-only** — never mutates ModelManager.
    private let modelState: () -> ModelManager.State

    /// Transcription hard timeout: `transcribe(...)` must return within this limit, otherwise it is treated as stalled and converged to an error hint.
    /// Defaults to 90s -- enough for local inference to complete on a loaded model, but guaranteeing "never permanently stuck transcribing". Tests can inject an extremely short value.
    private let transcribeTimeout: Duration

    /// Reads the trimmed cloud STT API key (the ``KeychainStore`` `openAIAPIKey` account by default). Injectable so tests
    /// can drive the cloud-key signature component without the real Keychain AND assert the read is not done on the
    /// per-dictation hot path (see ``cachedCloudKey``). `@Sendable` so it can be called from the off-main-actor prewarm path.
    private let cloudKeyReader: @Sendable () -> String

    /// Optional test sink that ALSO receives the pipeline metrics summary line (observability only). `nil` (production)
    /// means only the ``metricsLog`` `.notice` call runs; when present, the SAME formatted string is additionally handed to
    /// the sink so a headless test can assert "exactly one summary line per successful dictation, none on early exits"
    /// without scraping the system log. The production `metricsLog.notice` always fires regardless, so this never changes
    /// the shipped behavior. (Mirrors the injectable-seam pattern the init already uses.)
    private let metricsSink: ((String) -> Void)?

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
    ///   - modelState: reads the current ``ModelManager/State`` for truthful not-ready copy (downloading NN% vs no model yet); defaults to read-only reuse of ``ModelManager/shared``'s `state`.
    ///   - transcribeTimeout: the transcription hard timeout; defaults to 90s.
    ///   - soundCues: the start/stop chime player; defaults to the real ``SoundCuePlayer``. Tests can inject a no-op double.
    ///   - cloudKeyReader: reads the trimmed cloud STT API key; defaults to the ``KeychainStore`` `openAIAPIKey` account. Tests can inject it to drive the cloud-key signature and assert it is not read per dictation.
    ///   - axReader: the focused-element text reader for learn-from-edits; defaults to ``AXTextReader``. Tests inject a stub.
    ///   - suggestionPanel: the "add to dictionary?" prompt controller; defaults to the shared instance. Tests inject a fresh one.
    ///   - learnFreshness: how long an armed injection record stays fresh; defaults to ~120s. Tests pass a tiny/large value.
    ///   - learnIdleAfter: the no-keystroke idle window after which the compare fires; defaults to ~3s. Tests pass a tiny value.
    ///   - learnProviderFactory: builds the term-extraction provider; defaults to reusing ``makePolishProvider()``. Tests
    ///     inject one that returns a dummy provider (or throws to exercise the no-provider drop) without the real Keychain.
    ///   - termExtractorFactory: builds the learn-from-edits term extractor from a provider; defaults to a real
    ///     ``LearnedTermExtractor``. Tests inject a fake returning a chosen ``LearnedTerm`` / nil.
    init(config: AppConfig = .shared,
         hotkeyManager: HotkeyManager? = nil,
         recorder: AudioRecording = AudioRecorder(),
         panel: RecordingPanelController = .shared,
         injector: TextInjecting = TextInjector(),
         dictionaryStore: DictionaryStore = DictionaryStore(),
         transcriberFactory: (() throws -> any Transcriber)? = nil,
         accessibilityGate: (() -> Bool)? = nil,
         modelReadiness: ((String) -> Bool)? = nil,
         modelState: (() -> ModelManager.State)? = nil,
         transcribeTimeout: Duration = .seconds(90),
         soundCues: SoundCuePlaying = SoundCuePlayer(),
         cloudKeyReader: (@Sendable () -> String)? = nil,
         axReader: FocusedTextReading = AXTextReader(),
         suggestionPanel: SuggestionPanelController = .shared,
         learnFreshness: Duration = .seconds(120),
         learnIdleAfter: Duration = .seconds(3),
         learnProviderFactory: (() async throws -> any LLMProvider)? = nil,
         termExtractorFactory: ((any LLMProvider) -> any LearnedTermExtracting)? = nil,
         metricsSink: ((String) -> Void)? = nil) {
        self.config = config
        self.recorder = recorder
        self.panel = panel
        self.injector = injector
        self.dictionaryStore = dictionaryStore
        self.axReader = axReader
        self.suggestionPanel = suggestionPanel
        self.learnFreshness = learnFreshness
        self.learnIdleAfter = learnIdleAfter
        self.termExtractorFactory = termExtractorFactory ?? { LearnedTermExtractor(provider: $0) }
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
        // The default state reader read-only reuses the process-shared ModelManager.shared.state (main-actor, no network, no download).
        self.modelState = modelState ?? { ModelManager.shared.state }
        self.transcribeTimeout = transcribeTimeout
        // The default reader trims the openAIAPIKey from the Keychain (matching makeConfiguredTranscriber / the old currentSignature).
        self.cloudKeyReader = cloudKeyReader ?? {
            (KeychainStore.get(account: KeychainStore.Account.openAIAPIKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Store the override as-is; nil means buildLearnProvider() reuses makePolishProvider() (resolved at call time, so no
        // self-capturing closure is stored during init — which Swift forbids on a stored property).
        self.learnProviderFactoryOverride = learnProviderFactory
        self.metricsSink = metricsSink
    }

    /// Builds the term-extraction provider: the injected override if present, else reuses ``makePolishProvider()`` exactly
    /// (same provider/model/key path as polish). Throws when no provider/key is configured (the caller drops silently).
    private func buildLearnProvider() async throws -> any LLMProvider {
        if let learnProviderFactoryOverride {
            return try await learnProviderFactoryOverride()
        }
        return try await makePolishProvider()
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
        // Learn-from-edits (always on): every keystroke resets the idle timer (so the compare fires only after the user
        // pauses); a Return/keypad-Enter commit fires the compare immediately. Both are no-ops unless a fresh injection
        // record is armed, so wiring them is harmless when nothing is pending.
        hotkeyManager.onUserKeystroke = { [weak self] in self?.handleUserKeystroke() }
        hotkeyManager.onCommitKey = { [weak self] in self?.handleCommitKey() }
        // A Backspace / Forward-Delete marks that a real edit happened (the necessary signal a correction occurred): the
        // compare drops unless the user actually edited. Observe-only and a no-op unless a fresh record is armed.
        hotkeyManager.onEditKey = { [weak self] in self?.handleEditKey() }
        // Learn-from-edits focus-loss trigger: when the armed app deactivates (the user switched / clicked away) the edit
        // is treated as committed, so fire the compare once. Removed in stop().
        focusLossObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFocusLoss() }
        }
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
        // Learn-from-edits teardown: drop any armed record + in-flight idle timer + in-flight extraction + visible
        // suggestion so a stale record/suggestion never survives teardown (and a late timer/extraction can never fire after stop()).
        clearLearnFromEdits()
        if let focusLossObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(focusLossObserver)
            self.focusLossObserver = nil
        }
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

        // Learn-from-edits next-dictation policy: a new dictation is starting, so DROP any prior armed record (+ its idle
        // timer / in-flight extraction / visible suggestion). Never carry a stale record into a new dictation; the
        // Enter/idle/focus-loss triggers already cover the common commit cases for the prior inject.
        clearLearnFromEdits()

        // Record the injection target (for injection back-fill + focus-drift verification).
        capturedTarget = currentFrontmostTarget()

        // STT pre-flight gate: in local mode, if the model cannot possibly transcribe yet (not cached/loaded), do NOT
        // record — recording a full utterance only to discard it at the post-record :730 gate wastes the user's words and
        // their breath. Use the SAME cheap, network-free readiness signal as that gate (modelReadiness), but surface the
        // state-aware not-ready message immediately. Returns BEFORE panel.show(.listening) and BEFORE the start chime, so
        // the HUD goes straight to the error toast (no listening→error flicker, no misleading "started" chime). The :730
        // gate stays as a belt-and-suspenders backstop. Cloud mode is never gated here (CloudTranscriber needs no local model).
        if config.sttMode == .local, !modelReadiness(config.localModel) {
            showSetupBlockingError(modelNotReadyMessage())
            return
        }

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
        showTransientError(uiLanguageLocalized("hud.needAccessibility",
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
        // Learn-from-edits: an ESC cancel ends the session — drop any armed record / in-flight idle timer / in-flight
        // extraction / visible suggestion so a stale record from a prior inject can never trigger a suggestion after cancel.
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

    /// Observability-only per-dictation latency accumulator. Carries the total clock + its start instant (set at the
    /// pipeline entry, right after the user stops) plus per-stage wall-clock milliseconds, and the context needed for the
    /// summary line (STT mode, polish on/off, clip seconds). Stages that are skipped keep their default `0` (e.g. `prepareMs`
    /// stays 0 when the model is already warm; `polishMs` stays 0 when polish is off) — matching the spec's "0 when …".
    /// Built in ``runPipeline`` and threaded into ``injectFinalText`` so the line is emitted exactly once, only on the
    /// genuinely completed success path. No control-flow role: purely a data carrier read at emit time.
    private struct PipelineMetrics {
        let clock: ContinuousClock
        let pipelineStart: ContinuousClock.Instant
        var prepareMs = 0.0
        var sttMs = 0.0
        var dictMs = 0.0
        var polishMs = 0.0
        let mode: STTMode
        let polishOn: Bool
        var clipSeconds = 0.0
    }

    /// Converts a `ContinuousClock.Duration` to wall-clock milliseconds. Mirrors the #63 `WhisperKitTranscriber` math
    /// (`components.seconds + components.attoseconds / 1e18`, then * 1000) so both logs use the identical conversion.
    private static func milliseconds(_ duration: ContinuousClock.Duration) -> Double {
        let c = duration.components
        return (Double(c.seconds) + Double(c.attoseconds) / 1e18) * 1000
    }

    /// The complete pipeline: stop recording -> transcribe -> (optional) polish -> inject. Runs in a background task, switching back to the main thread for UI calls.
    /// - Parameter pendingStart: this round's recording start Task (may still be in progress); `await` its completion before stopping.
    private func runPipeline(awaiting pendingStart: Task<Void, Never>?) async {
        // Observability only (no behavior change): start the end-to-end clock at the pipeline entry — "right after the user
        // stops dictation". Placed before the start-await so the total also captures the short-press join (part of the
        // stop->ready latency); this and every stage read below are pure measurement around the EXISTING stages, never
        // reordering / branching / returning differently. The summary line is emitted once, only on the success path.
        let clock = ContinuousClock()
        let pipelineStart = clock.now
        var metrics = PipelineMetrics(
            clock: clock,
            pipelineStart: pipelineStart,
            mode: config.sttMode,
            polishOn: config.polishEnabled
        )
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
            failToIdle(message: uiLanguageLocalized("hud.stopRecordingFailed",
                                                    defaultValue: "Failed to finish recording"))
            return
        }

        // Empty audio (nothing said): do not transcribe, do not inject, briefly hint then idle.
        guard !samples.isEmpty else {
            emptyToIdle()
            return
        }

        // Metrics context (observability only): the clip length the rest of the pipeline operates on.
        metrics.clipSeconds = Double(samples.count) / AudioFormat.sampleRate

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
            // 1.75) Local model cold-start gate: the WhisperKit engine may be DOWNLOADED (passed the 1.5 gate above) yet not
            // yet LOADED INTO MEMORY — right after launch (before opportunistic prewarm finishes) or right after a model
            // switch (currentTranscriber() rebuilds + kicks a background preload, so isReady is briefly false). In that case a
            // transcribe call blocks on the CoreML load for several seconds while the HUD shows "Transcribing…", looking
            // frozen. So when the local model is NOT ready, first show a "Preparing model…" HUD state, then AWAIT the load
            // (joining the in-flight background prewarm; idempotent) before switching to the normal transcribing phase. When
            // the model is already warm (the common post-prewarm case) this is skipped entirely — zero "preparing" flash,
            // byte-identical to before. Cloud mode never enters this branch (CloudTranscriber.isReady defaults to true).
            // The preload is wrapped in the SAME timeout envelope as transcribe, and a load failure throws STTError, so both
            // fall through to the existing TranscribeTimeout / STTError catch arms below — the preparing state can never hang.
            if config.sttMode == .local, await transcriber.isReady == false {
                // Metrics (observability only): bracket the model load/warmup wait. When this branch is skipped (warm model
                // / cloud) prepareMs stays 0 — exactly "0 when the model was already warm".
                let prepareStart = clock.now
                updateProcessing(0.0, .preparingModel)
                _ = try await withTranscribeTimeout {
                    try await transcriber.preload()
                }
                updateProcessing(0.0, .transcribing)
                metrics.prepareMs = Self.milliseconds(clock.now - prepareStart)
            }
            // User-dictionary Layer 1 biasing: order the enabled entries' canonical terms by usageCount ascending
            // (most-used LAST, see GlossaryPrompt) and pass them as biasing options so STT is steered toward the user's
            // dictionary words (best-effort recall boost). Ordering happens HERE, at the single source, so the documented
            // usageCount ordering actually reaches the transcriber and the token-cap suffix keeps the highest-usage terms.
            // An empty dictionary -> empty terms -> no prompt is built anywhere (byte-identical to before this feature).
            let biasTerms = GlossaryPrompt.orderedCanonicals(from: entries)
            // Speech recognition always auto-detects the language (T24): always passes nil to let the backend judge by the speech, no longer reading AppConfig.language.
            // Metrics (observability only): bracket the coordinator-side transcribe await (the transcribe wrapper). The #63
            // `stt` line measures pure WhisperKit inference — both are kept (this is the higher-level end-to-end breakdown).
            let sttStart = clock.now
            let result = try await withTranscribeTimeout {
                try await transcriber.transcribe(
                    samples,
                    sampleRate: AudioFormat.sampleRate,
                    language: nil,
                    options: TranscribeOptions(biasTerms: biasTerms)
                )
            }
            metrics.sttMs = Self.milliseconds(clock.now - sttStart)
            transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            // ESC cancelled the dictation mid-transcribe: abort silently (the user intentionally aborted), no HUD error flash, inject nothing.
            // withTranscribeTimeout's child tasks inherit cancellation, so an outer cancel makes the inner transcribe/Task.sleep throw CancellationError that surfaces here.
            return
        } catch is TranscribeTimeout {
            // Hard timeout: transcription does not return in time (e.g. the underlying layer stuck loading/downloading the model). Give an error hint and converge to idle.
            failToIdle(message: uiLanguageLocalized("hud.transcriptionFailed", defaultValue: "Transcription failed"))
            return
        } catch let error as STTError {
            failToIdle(message: Self.transcriptionFailureMessage(error))
            return
        } catch {
            failToIdle(message: uiLanguageLocalized("hud.transcriptionFailed", defaultValue: "Transcription failed"))
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
        // Metrics (observability only): bracket the polish step. When polish is off, polishIfEnabled returns immediately so
        // polishMs stays ~0 and the summary is tagged polish=off (the spec allows omit-or-0).
        let polishStart = clock.now
        let polished = await polishIfEnabled(transcript, entries: entries)
        metrics.polishMs = Self.milliseconds(clock.now - polishStart)

        // ESC cancel during polish: discard the polished result and inject nothing.
        guard !Task.isCancelled else { return }

        // Polish done: fill the progress bar to 100% (with polish off it was already set to 1.0 above, idempotent here).
        if config.polishEnabled {
            updateProcessing(1.0, .polishing)
        }

        // 3.5) User-dictionary Layer 3: deterministic rewriting (exact case / spacing) after polish, before injection.
        //      Reuses the same per-utterance `entries` snapshot (no extra actor read). An empty dictionary is identity (zero behavior change).
        // Metrics (observability only): bracket the Layer-3 dictionary rewrite.
        let dictStart = clock.now
        let finalText = DictionaryRewriter.apply(to: polished.text, using: entries)
        metrics.dictMs = Self.milliseconds(clock.now - dictStart)

        // Load-bearing cancel guard: even if transcribe + polish + dictionary all completed, an ESC cancel before this line means injectFinalText is never reached — no text is injected.
        guard !Task.isCancelled else { return }

        // 4) Inject at the target App's cursor (with a light hint on polish failure, but never losing characters).
        //    Threads the accumulated metrics so the one-line summary is emitted from inside the `.success` branch — the sole
        //    place injection actually completed (every early exit above already returned, so no misleading success line).
        injectFinalText(finalText, polishCategory: polished.category, metrics: metrics)
    }

    // MARK: Polish

    /// Why polish did NOT produce a polished result, carried out of ``polishIfEnabled(_:entries:)`` so ``injectFinalText`` can
    /// choose truthful, actionable copy instead of collapsing "not configured" and "runtime failure" into one boolean.
    /// Internal (not `private`) only so `@testable` tests can construct it to drive ``injectFinalText`` directly; it is not part of any public surface.
    enum PolishFailureCategory: Equatable {
        /// Polish ran (or was off) and there is nothing to hint — insert silently. Covers polish-off and `.polished`.
        case none
        /// Polish is enabled but has NO usable credentials (the caught ``ProviderError/missingAPIKey``): the call never ran.
        /// Drives a provider-aware "sign in / add an API key under Settings ▸ Polish" hint (actionable, not a scary failure).
        case notConfigured
        /// Polish is configured (credentials present) but the call genuinely failed at runtime and fell back to the original.
        /// Drives the generic "polish failed, used original text" hint.
        case failed
    }

    /// The result of one polish step: the final text + WHY polish did not polish (for an optional, category-aware hint after injection).
    private struct PolishStep {
        let text: String
        /// The reason polish did not produce a polished result; `.none` means insert silently (polish off or succeeded).
        let category: PolishFailureCategory
    }

    /// Classifies a polish-provider CONSTRUCTION error into a failure category: ``ProviderError/missingAPIKey`` (an empty BYO
    /// key or a missing ChatGPT OAuth token) is a fixable setup gap → `.notConfigured`; any other error is a genuine runtime
    /// failure → `.failed`. Pure + `static` so the missingAPIKey-vs-other mapping is unit-testable without the Keychain.
    static func constructionFailureCategory(_ error: Error) -> PolishFailureCategory {
        if case ProviderError.missingAPIKey = error { return .notConfigured }
        return .failed
    }

    /// Polishes per the config; both Provider construction failure / polish failure fall back to the original (never losing characters).
    /// - Parameter entries: the per-utterance dictionary snapshot (shared with Layer 1/3), used to build the Layer 2 glossary.
    private func polishIfEnabled(_ transcript: String, entries: [DictionaryEntry]) async -> PolishStep {
        guard config.polishEnabled else { return PolishStep(text: transcript, category: .none) }

        let provider: any LLMProvider
        do {
            provider = try await makePolishProvider()
        } catch {
            // Provider construction failed: use the original directly (not blocking injection), but distinguish WHY for the
            // hint via the pure classifier below — a missing API key / missing OAuth token (ProviderError.missingAPIKey) is
            // "not configured" (a setup gap the user can fix in Settings ▸ Polish); any other construction error is a runtime failure.
            NSLog("[SayIt] 润色 Provider 构造失败，回退原文: %@", String(describing: error))
            return PolishStep(text: transcript, category: Self.constructionFailureCategory(error))
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
        // Only .failedFallback is a genuine runtime failure (credentials present, the call failed); .polished / .skipped do not hint.
        let category: PolishFailureCategory
        if case .failedFallback = outcome.resolution { category = .failed } else { category = .none }
        return PolishStep(text: outcome.text, category: category)
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
    ///
    /// Generic over the work's result so the SAME timeout envelope (and its ``TranscribeTimeout`` -> idle catch arm in
    /// ``runPipeline``) also bounds the cold-start model `preload()` (returning `Void`): the preparing-model gate can never
    /// hang. The marker error + `group.cancelAll()` + cancellation semantics are unchanged for the existing transcribe call.
    /// - Parameter work: the actual async work closure (transcribe -> ``TranscriptionResult``, or preload -> `Void`).
    private func withTranscribeTimeout<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = transcribeTimeout
        return try await withThrowingTaskGroup(of: T.self) { group in
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
    ///   - polishCategory: WHY polish did not polish (only used for a category-aware hint after successful injection, not affecting the injection itself):
    ///     `.none` inserts silently; `.notConfigured` shows a provider-aware "sign in / add an API key under Settings ▸ Polish" hint; `.failed` shows the generic "polish failed" hint.
    ///   - metrics: the accumulated per-stage pipeline metrics (observability only). When non-nil AND injection succeeds,
    ///     ONE `.notice` summary line is emitted (the inject stage timed here, total measured to now). `nil` (e.g. older
    ///     test callsites) emits nothing. Never affects injection behavior — purely read at emit time.
    private func injectFinalText(_ text: String, polishCategory: PolishFailureCategory, metrics: PipelineMetrics? = nil) {
        let drifted = focusDrifted()
        // Metrics (observability only): bracket the injection (pasteboard + paste / AX). Read regardless of outcome; only
        // emitted below on `.success` (the sole place injection completed — `.failedTextLeftInPasteboard` did NOT inject).
        let injectStart = metrics?.clock.now
        let result = injector.inject(text)

        switch result {
        case .success:
            // Emit the ONE end-to-end summary line, only here on the genuinely completed success path (text injected). Every
            // early exit upstream already returned, and the pasteboard-fallback branch below does NOT emit — so the line is
            // never a misleading success. No text is logged, only its char count.
            if let metrics, let injectStart {
                let injectMs = Self.milliseconds(metrics.clock.now - injectStart)
                let totalMs = Self.milliseconds(metrics.clock.now - metrics.pipelineStart)
                emitPipelineMetrics(metrics, injectMs: injectMs, totalMs: totalMs, chars: text.count)
            }
            if drifted {
                // Focus drifted but the paste still succeeded: give a brief neutral (genuine-success) hint, informing it was pasted into the current window.
                showTransientInfo(uiLanguageLocalized("hud.pastedToCurrentWindow",
                                                      defaultValue: "Pasted to the current window"))
            } else {
                switch polishCategory {
                case .notConfigured:
                    // Injection succeeded but polish is enabled with no usable credentials: a provider-aware, actionable hint
                    // routed through the non-success setup-blocking presentation (red, persistent) — NOT a green checkmark.
                    showSetupBlockingError(insertedNoPolishMessage())
                case .failed:
                    // Injection succeeded but polish was configured and genuinely failed at runtime, falling back to the
                    // original: the generic hint, routed through the non-success presentation (a failure is not a success).
                    showSetupBlockingError(uiLanguageLocalized("hud.injectedPolishFailed",
                                                               defaultValue: "Inserted (polish failed, used original text)"))
                case .none:
                    // Polish off or succeeded: silent insertion (unchanged).
                    panel.hide()
                    phase = .idle
                }
            }
            // Learn-from-edits ARM: only on a clean, non-drifted success (the focus target did not move, so the just-injected
            // text is what the focused field now holds). Drift means the paste landed elsewhere, so there is nothing reliable
            // to compare later — skip arming there. No-op internally when the field is unreadable (see armLearnFromEdits).
            if !drifted {
                armLearnFromEdits(injected: text)
            } else {
                Self.log.notice("arm: skipped (drifted)")
            }
        case .failedTextLeftInPasteboard:
            // The text is left in the clipboard, hinting the user to paste manually.
            let hint = drifted
                ? uiLanguageLocalized("hud.driftedCopiedPasteManually",
                                      defaultValue: "Focus changed — text copied, please paste manually")
                : uiLanguageLocalized("hud.copiedPasteManually",
                                      defaultValue: "Copied to clipboard, please paste manually")
            showTransientError(hint)
        }
    }

    /// Provider-aware, actionable copy for "inserted without polish because polish has no usable credentials", chosen by
    /// ``AppConfig/providerKind``: the ChatGPT (Codex OAuth) provider authenticates by signing in, the BYO providers
    /// (OpenAI / DeepSeek / Anthropic) authenticate with an API key, so each names the exact fix in Settings ▸ Polish.
    /// Both en + zh-Hans live in the App catalog via ``uiLanguageLocalized``.
    private func insertedNoPolishMessage() -> String {
        switch config.providerKind {
        case .chatGPT:
            return uiLanguageLocalized("hud.insertedNoPolishSignIn",
                                       defaultValue: "Inserted without polish — sign in to ChatGPT under Settings ▸ Polish.")
        case .openAI, .deepSeek, .anthropic:
            return uiLanguageLocalized("hud.insertedNoPolishAddKey",
                                       defaultValue: "Inserted without polish — add an API key under Settings ▸ Polish.")
        }
    }

    /// Builds and emits the ONE end-to-end pipeline metrics summary line for a completed dictation (observability only).
    /// Format is concise, parseable `key=value` (mirrors the #63 `stt` line style), e.g.
    /// `pipeline: total=1820ms stt=410ms dict=2ms polish=1290ms inject=70ms prepare=0ms mode=local polish=on clip=2.3s chars=14`.
    /// Always logs at `.notice` to ``metricsLog``; ALSO hands the same string to ``metricsSink`` when a test injected one.
    /// Only numbers are interpolated (`privacy: .public`); the transcribed/injected TEXT is never logged, only `chars`. The
    /// `mode`/`polish` tags are precomputed `String`s because `os.Logger` cannot take a ternary mixing types in interpolation
    /// (the same trick the learn-flow logging uses).
    private func emitPipelineMetrics(_ metrics: PipelineMetrics, injectMs: Double, totalMs: Double, chars: Int) {
        let modeTag = metrics.mode == .local ? "local" : "cloud"
        let polishTag = metrics.polishOn ? "on" : "off"
        let line = "pipeline: "
            + "total=\(Int(totalMs.rounded()))ms "
            + "stt=\(Int(metrics.sttMs.rounded()))ms "
            + "dict=\(Int(metrics.dictMs.rounded()))ms "
            + "polish=\(Int(metrics.polishMs.rounded()))ms "
            + "inject=\(Int(injectMs.rounded()))ms "
            + "prepare=\(Int(metrics.prepareMs.rounded()))ms "
            + "mode=\(modeTag) "
            + "polish=\(polishTag) "
            + "clip=\(String(format: "%.1f", metrics.clipSeconds))s "
            + "chars=\(chars)"
        Self.metricsLog.notice("\(line, privacy: .public)")
        metricsSink?(line)
    }

    /// Whether the injection target is no longer frontmost (focus drift). When there is no recorded target it is treated as no drift.
    private func focusDrifted() -> Bool {
        guard let captured = capturedTarget,
              let current = currentFrontmostTarget() else {
            return false
        }
        return captured.processIdentifier != current.processIdentifier
    }

    // MARK: Learn from edits (Part B v2 — always on)
    //
    // The feature is unconditionally active (no opt-in). Flow: ARM after a clean, non-drifted inject when the focused
    // field is readable -> the user edits in place -> the compare fires when editing is DONE (commit Return/keypad-Enter,
    // focus loss, ~idle of keystrokes, or a new dictation), whichever happens FIRST, exactly ONCE per armed inject ->
    // read the FINAL focused text via AX -> send (injected, final) to the LLM term extractor -> apply a hard single-term
    // guard -> if a single corrected term is found, SUGGEST adding it. No local diff, so a sentence can never be suggested.

    /// ARM: snapshot the just-injected text as the extraction baseline, but ONLY when the focused field's text is currently
    /// readable (we cannot compare what we cannot read — secure/web/terminal fields return nil here). Replaces any prior
    /// record (the latest inject is the only one worth learning from), captures a lightweight focus identity + a generous
    /// freshness expiry, and starts the idle timer (so a long pause after the inject still triggers a compare).
    private func armLearnFromEdits(injected: String) {
        // Every arm attempt starts clean: no edit has happened yet for this (re)arm. Reset BEFORE the AX guard so even an
        // arm that bails on an unreadable field leaves no stale "edited" signal behind.
        didEdit = false
        // Drop any prior idle timer / in-flight extraction: a new inject supersedes an older pending one.
        idleTimerTask?.cancel()
        idleTimerTask = nil
        extractTask?.cancel()
        extractTask = nil
        // Read the focused field right after the paste landed. nil (secure/unreadable) -> do not arm (can't compare later).
        guard axReader.readFocusedText() != nil else {
            Self.log.notice("arm: AX unreadable -> not armed")
            injectionRecord = nil
            return
        }
        injectionRecord = InjectionRecord(
            injectedText: injected,
            expiresAt: Date().addingTimeInterval(learnFreshness.timeIntervalValue),
            armedAt: Date(),
            targetPID: capturedTarget?.processIdentifier
        )
        startIdleTimer()
        Self.log.notice("armed (injectedLen=\(injected.count, privacy: .public), freshness=\(self.learnFreshness.timeIntervalValue, privacy: .public)s)")
    }

    /// Starts/restarts the idle timer: after ``learnIdleAfter`` of no keystrokes (while armed) the compare fires. Reset on
    /// every keystroke (cancel + reschedule). A no-op when nothing is armed.
    private func startIdleTimer() {
        guard injectionRecord != nil else { return }
        idleTimerTask?.cancel()
        idleTimerTask = Task { [weak self, learnIdleAfter] in
            try? await Task.sleep(for: learnIdleAfter)
            if Task.isCancelled { return }
            guard let self else { return }
            Self.log.notice("trigger=idle")
            self.fireCompare()
        }
    }

    /// KEYSTROKE: any keyDown while armed resets the idle timer (so the compare fires only after the user pauses). A no-op
    /// when nothing is armed (the common case), so it never interferes with normal typing.
    private func handleUserKeystroke() {
        guard injectionRecord != nil else { return }
        Self.log.notice("keystroke (armed=\(self.injectionRecord != nil, privacy: .public))")
        startIdleTimer()
    }

    /// EDIT KEY (Backspace / Forward-Delete): a real correction must involve a delete, so this is the necessary signal that
    /// the user actually edited the inject. Flips ``didEdit`` only while armed (symmetric with ``handleUserKeystroke``); a
    /// no-op when nothing is armed, so a stray delete from an earlier moment never leaks into a later arm.
    private func handleEditKey() {
        guard injectionRecord != nil else { return }
        didEdit = true
        Self.log.notice("editKey (armed=\(self.injectionRecord != nil, privacy: .public))")
    }

    /// COMMIT (Return / keypad-Enter): the edit is done — fire the compare immediately. A no-op when nothing is armed.
    private func handleCommitKey() {
        Self.log.notice("trigger=commit (armed=\(self.injectionRecord != nil, privacy: .public))")
        guard injectionRecord != nil else { return }
        fireCompare()
    }

    /// FOCUS LOSS (the armed app deactivated): the user switched / clicked away — treat the edit as committed and fire the
    /// compare. A no-op when nothing is armed.
    private func handleFocusLoss() {
        Self.log.notice("trigger=focusLoss (armed=\(self.injectionRecord != nil, privacy: .public))")
        guard injectionRecord != nil else { return }
        fireCompare()
    }

    /// TRIGGER -> COMPARE: consume the armed record exactly once (Enter + idle + focus-loss can race; clearing the record
    /// here makes subsequent triggers no-ops), then read the FINAL focused text and run the LLM extraction. Drops silently
    /// when: the record is missing/expired, the AX read returns nil, the final text equals the injected text (no edit), no
    /// provider/key is configured, or the LLM errors/times out / returns no single-term result.
    private func fireCompare() {
        guard let record = injectionRecord else {
            Self.log.notice("compare: no record")
            return
        }
        // Consume the record up front so a racing trigger (Enter then idle, etc.) cannot run the compare twice. Cancel the
        // idle timer too (its scheduled fire is now moot).
        injectionRecord = nil
        idleTimerTask?.cancel()
        idleTimerTask = nil

        // Expired -> the user moved on long ago; drop without reading.
        guard record.expiresAt > Date() else {
            Self.log.notice("compare: expired")
            return
        }

        // Require a real edit: a correction must involve a delete (Backspace / Forward-Delete). With no edit key seen since
        // arming, the user did not correct anything (e.g. dictate + Enter), so drop WITHOUT reading AX or calling the LLM.
        guard didEdit else {
            Self.log.notice("compare: no edit key seen -> drop")
            return
        }

        // Read the FINAL focused text. nil -> no longer readable (moved away / secure) -> drop silently.
        guard let final = axReader.readFocusedText() else {
            Self.log.notice("compare: AX final unreadable")
            return
        }
        // Identical to what we injected -> the user made no edit -> drop WITHOUT calling the LLM.
        guard final.value != record.injectedText else {
            Self.log.notice("compare: no edit (final==injected)")
            return
        }
        Self.log.notice("compare: proceeding injected=\(record.injectedText, privacy: .public) final=\(final.value, privacy: .public)")

        // Build the provider exactly like polish; no provider/key configured -> feature inactive -> drop silently.
        extractTask?.cancel()
        extractTask = Task { [weak self] in
            guard let self else { return }
            let provider: any LLMProvider
            do {
                provider = try await self.buildLearnProvider()
            } catch {
                Self.log.error("compare: provider build FAILED: \(error.localizedDescription, privacy: .public)")
                return    // no provider / key -> drop silently.
            }
            if Task.isCancelled { return }
            let extractor = self.termExtractorFactory(provider)
            let term = await extractor.extract(injected: record.injectedText, final: final.value)
            if Task.isCancelled { return }
            guard let term, Self.passesSingleTermGuard(term, finalText: final.value) else {
                // Diagnostics only: choose the message by the already-evaluated `term == nil` (a string choice, not control
                // flow — both branches just log then hit the same `return`). Two `notice` calls because `os.Logger`
                // requires a literal string-interpolation argument and cannot take a ternary across interpolation types.
                if let rejected = term {
                    Self.log.notice("compare: guard REJECTED (heard=\(rejected.heard, privacy: .public), corrected=\(rejected.corrected, privacy: .public))")
                } else {
                    Self.log.notice("compare: extractor returned nil")
                }
                return    // not a single-term correction, or the guard rejected it -> drop silently.
            }
            Self.log.notice("compare: SUGGESTING (heard=\(term.heard, privacy: .public), corrected=\(term.corrected, privacy: .public))")
            self.presentSuggestion(heard: term.heard, corrected: term.corrected)
        }
    }

    /// HARD single-term guard, applied to the extractor's result before suggesting. Structurally prevents the "whole
    /// sentence" bug even if the LLM misbehaves: `corrected` must be non-empty, differ from `heard`, be short (<= 40
    /// chars), contain NO sentence punctuation / newline beyond what a single identifier could hold, and must not be or
    /// contain the whole final sentence.
    static func passesSingleTermGuard(_ term: LearnedTerm, finalText: String) -> Bool {
        let corrected = term.corrected
        guard !corrected.isEmpty else { return false }
        guard corrected != term.heard else { return false }
        guard corrected.count <= 40 else { return false }
        // Reject sentence punctuation / newlines a single proper-noun / brand / identifier would never contain.
        let forbidden = CharacterSet(charactersIn: "。．.,!?！？、\n\r")
        guard corrected.rangeOfCharacter(from: forbidden) == nil else { return false }
        // The corrected term must not be the whole final sentence (or, defensively, contain it).
        let trimmedFinal = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard corrected != trimmedFinal else { return false }
        guard !corrected.contains(trimmedFinal) || trimmedFinal.isEmpty else { return false }
        return true
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

    /// Clears all learn-from-edits transient state: the armed record, the in-flight idle timer, any in-flight extraction,
    /// and any visible suggestion. Called on teardown (``stop()``), ESC cancel (``cancel()``), and at the start of a new
    /// dictation (``handleStart()``) so a stale record never carries into a new dictation.
    private func clearLearnFromEdits() {
        injectionRecord = nil
        idleTimerTask?.cancel()
        idleTimerTask = nil
        extractTask?.cancel()
        extractTask = nil
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
        showTransientError(uiLanguageLocalized("hud.didNotCatchThat", defaultValue: "Didn’t catch that, please try again"))
    }

    /// Local model not ready: the HUD shows a state-aware, actionable not-ready hint then returns to idle, and does not enter transcription.
    /// Routed through ``showSetupBlockingError(_:)`` so it is a non-success (`.error`, NOT green `.info`) toast that stays on screen
    /// long enough to read and act on. This is the post-record :730 backstop; the primary block is the ``handleStart()`` pre-flight gate,
    /// which uses the SAME ``modelNotReadyMessage()`` copy so both paths tell the user the same truthful story.
    private func modelNotReadyToIdle() {
        showSetupBlockingError(modelNotReadyMessage())
    }

    /// Truthful, actionable copy for "the local model is not ready to transcribe", chosen by reading ``ModelManager``'s
    /// published state (via the injectable ``modelState`` seam) instead of always claiming "still downloading":
    /// - `.downloading(progress:)`: "Local model downloading… NN% — please wait" (truthful, since first launch auto-downloads).
    /// - `.notDownloaded` / `.failed`: "No local model yet — open Settings ▸ Speech to download (or switch to Cloud)." (actionable).
    /// The `.downloaded` arm is logically unreachable when not-ready (the gate only fires when ``modelReadiness`` is false),
    /// so it falls back to the safe in-bundle ``RecordingState/modelNotReadyMessage`` rather than asserting.
    /// Both en + zh-Hans live in the App catalog (read via ``uiLanguageLocalized`` / its format variant), mirroring the
    /// menu-bar `menu.modelDownloading %d` line; SayItCore's `hud.modelNotReady` stays untouched as the fallback.
    private func modelNotReadyMessage() -> String {
        switch modelState() {
        case .downloading(let progress, _):
            let pct = Int((progress * 100).rounded())
            return uiLanguageLocalized(format: "hud.modelDownloadingPct %d",
                                       defaultValue: "Local model downloading… %d%% — please wait",
                                       pct)
        case .notDownloaded, .failed:
            return uiLanguageLocalized("hud.noLocalModel",
                                       defaultValue: "No local model yet — open Settings ▸ Speech to download (or switch to Cloud).")
        case .downloaded:
            return RecordingState.modelNotReadyMessage
        }
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

    /// Shows a SETUP-BLOCKING error on the HUD (model-not-ready, polish-not-configured): a non-success `.error` toast
    /// (red exclamation, NOT the green `.info` checkmark — a failure must never look like success) held NOTICEABLY LONGER
    /// (~6s vs the 1.6s used for ordinary transient hints like "didn't catch that") so the user can read it AND act on the
    /// named Settings location before it auto-hides. Reuses the same ``showTransient(_:duration:)`` mechanism — no parallel
    /// state store, no panel rewrite.
    private func showSetupBlockingError(_ message: String) {
        showTransient(.error(message), duration: .seconds(6))
    }

    /// Briefly shows a transient state (error / info) on the HUD, then automatically hides and returns to idle.
    /// - Parameter duration: how long the message stays before the delayed-hide fires. Defaults to 1.6s for ordinary
    ///   transient hints (didn't-catch-that, drift, paste-manually); setup-blocking messages pass a longer value via
    ///   ``showSetupBlockingError(_:)`` so they persist long enough to read and act on.
    private func showTransient(_ state: RecordingState, duration: Duration = .seconds(1.6)) {
        phase = .idle
        panel.update(state: state)
        // Cancel+replace any prior in-flight delayed-hide so only the LATEST transient owns panel.hide().
        transientTask?.cancel()
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
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
            return uiLanguageLocalized("hud.needMicrophone", defaultValue: "Microphone permission required")
        }
        return uiLanguageLocalized("hud.cannotStartRecording", defaultValue: "Cannot start recording")
    }

    /// The user-facing copy for transcription failure.
    private static func transcriptionFailureMessage(_ error: STTError) -> String {
        switch error {
        case .notReady:
            return uiLanguageLocalized("hud.transcriberNotReady",
                                       defaultValue: "Transcription not ready — check model/API key")
        case .emptyAudio:
            return uiLanguageLocalized("hud.didNotCatchThat", defaultValue: "Didn’t catch that, please try again")
        case .unsupportedFormat:
            return uiLanguageLocalized("hud.unsupportedAudioFormat", defaultValue: "Unsupported audio format")
        case .transcriptionFailed:
            return uiLanguageLocalized("hud.transcriptionFailed", defaultValue: "Transcription failed")
        @unknown default:
            return uiLanguageLocalized("hud.transcriptionFailed", defaultValue: "Transcription failed")
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

    /// Directly drives ``injectFinalText(_:polishCategory:metrics:)`` with a chosen category, so a test can assert the
    /// category-aware, provider-aware copy + the non-success (`.error`) routing on the visible `panel.currentState`,
    /// without standing up the full transcribe/polish pipeline. Metrics omitted (nil) so nothing is emitted.
    func _test_injectFinalText(_ text: String, polishCategory: PolishFailureCategory) {
        injectFinalText(text, polishCategory: polishCategory)
    }

    /// Computes the state-aware model-not-ready copy (downloading NN% vs no-model) via the injected ``modelState`` seam.
    /// Lets a test assert the truthful message selection without driving the recorder/pipeline.
    func _test_modelNotReadyMessage() -> String { modelNotReadyMessage() }

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

    /// Whether an injection record is currently armed (learn-from-edits). Lets a test assert ARM happened (field readable)
    /// or did NOT (AX nil), without exposing the private record's contents.
    var _test_injectionRecordArmed: Bool { injectionRecord != nil }

    /// Force-arms a learn-from-edits injection record with a custom expiry, bypassing the AX read at arm time. Lets a test
    /// exercise the expired-record path deterministically (pass a past `expiresAt`) without waiting the real freshness window.
    func _test_armInjectionRecord(injected: String, expiresAt: Date) {
        injectionRecord = InjectionRecord(injectedText: injected, expiresAt: expiresAt, armedAt: Date(), targetPID: nil)
    }

    /// Directly drives the COMMIT trigger (equivalent to a Return / keypad-Enter while armed), then awaits the in-flight
    /// extraction so the test is deterministic. No-op if nothing is armed.
    func _test_handleCommitKey() async {
        handleCommitKey()
        await extractTask?.value
    }

    /// Directly drives the FOCUS-LOSS trigger (equivalent to the armed app deactivating), then awaits the in-flight
    /// extraction so the test is deterministic. No-op if nothing is armed.
    func _test_handleFocusLoss() async {
        handleFocusLoss()
        await extractTask?.value
    }

    /// Directly drives one keystroke (equivalent to a keyDown while armed): resets the idle timer. For tests asserting the
    /// idle-timer reset path.
    func _test_handleUserKeystroke() { handleUserKeystroke() }

    /// Directly drives one edit key (equivalent to a Backspace / Forward-Delete keyDown while armed): flips the didEdit gate
    /// so a subsequent commit / idle / focus-loss trigger can fire the compare. For tests of the edit-required gate.
    func _test_handleEditKey() { handleEditKey() }

    /// Awaits the idle-timer fire AND the extraction it kicks off, so a test using a tiny `learnIdleAfter` can
    /// deterministically observe the idle-triggered compare. No-op if nothing is armed / no idle timer is running.
    func _test_awaitIdleCompare() async {
        await idleTimerTask?.value
        await extractTask?.value
    }

    /// Awaits any in-flight term-extraction task (no-op if none). Lets a test wait for an async compare to finish.
    func _test_awaitExtraction() async { await extractTask?.value }

    /// Exposes the suggestion panel so a test can drive Accept/Dismiss and assert visibility deterministically.
    var _test_suggestionPanel: SuggestionPanelController { suggestionPanel }
}

/// Converts a `Duration` to a `TimeInterval` (seconds) for `Date` arithmetic. `Duration.components` yields whole seconds +
/// attoseconds (1e-18); both are summed so sub-second freshness values survive the conversion.
private extension Duration {
    var timeIntervalValue: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
