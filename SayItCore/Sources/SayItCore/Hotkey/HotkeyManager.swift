import AppKit

/// Global hotkey manager: listens for system-level key events and emits `.start` / `.stop` events per the selected mode.
///
/// Supports two modes (see ``HotkeyMode``):
/// - **hold-to-talk**: hold the trigger key to speak (keyDown -> `.start`, keyUp -> `.stop`).
/// - **single-tap-to-toggle**: an isolated tap of the modifier key starts, another tap ends (default). An "isolated tap" =
///   the modifier key goes down -> up with no ordinary key in between, completed within a short window, so it does not conflict with shortcuts like Cmd-C.
///
/// Events are emitted in two ways, both active simultaneously:
/// - the callback ``onEvent`` (invoked on the main thread);
/// - the async sequence ``events`` (`AsyncStream`, convenient for `for await` consumption).
///
/// ## Required system permissions
/// Globally monitoring other apps' key events is a sensitive operation; macOS requires user authorization, one or both depending on the API used:
/// - **Accessibility**: System Settings > Privacy & Security > Accessibility.
///   `NSEvent.addGlobalMonitorForEvents` listening for `.keyDown` / `.keyUp` usually needs this.
/// - **Input Monitoring**: System Settings > Privacy & Security > Input Monitoring.
///   This is needed if you switch to `CGEventTap` to intercept keys instead.
///
/// This implementation uses `NSEvent` global monitoring (observe only, no interception or blocking of events), relying primarily on Accessibility authorization.
/// When unauthorized, the monitor is created but receives no callbacks -- callers should first check with ``isProcessTrusted`` and guide the user to authorize.
///
/// This type is `@MainActor`: the `NSEvent` monitoring API must be used on the main thread, and state is read/written only on the main thread.
@MainActor
public final class HotkeyManager {

    // MARK: Configuration

    /// The current trigger key. Changes take effect on the next event; read live inside the monitoring callback, no restart needed.
    public var triggerKey: TriggerKey

    /// The current mode. Changing it resets the internal state machine to avoid cross-mode residue.
    public var mode: HotkeyMode {
        didSet {
            guard oldValue != mode else { return }
            resetStateMachines()
        }
    }

    /// The maximum down -> up interval (seconds) used by single-tap mode to judge an "isolated tap".
    public let singleTapWindow: TimeInterval

    /// The macOS virtual keyCode for the ESC key (used to cancel an in-progress dictation; mirrors ``TriggerKey``'s named-keyCode style instead of a bare magic number).
    private let escapeKeyCode: UInt16 = 53

    /// The macOS virtual keyCode for the Backspace (Delete-back) key. Kept observe-only (it returns early so it never
    /// taints the single-tap candidate); mirrors ``escapeKeyCode``'s named-keyCode style instead of a bare magic number.
    private let backspaceKeyCode: UInt16 = 51

    /// The macOS virtual keyCode for the Forward-Delete key. The other observe-only edit key alongside ``backspaceKeyCode``.
    private let forwardDeleteKeyCode: UInt16 = 117

    /// The macOS virtual keyCode for the main Return / Enter key. A "commit" signal for the learn-from-edits feature: when
    /// the user presses it the field edit is considered DONE, so the coordinator fires its compare. Observe-only.
    private let returnKeyCode: UInt16 = 36

    /// The macOS virtual keyCode for the keypad Enter key. The other "commit" key alongside ``returnKeyCode``.
    private let keypadEnterKeyCode: UInt16 = 76

    // MARK: Event output

    /// Main-thread event callback (active simultaneously with ``events``).
    public var onEvent: ((HotkeyEvent) -> Void)?

    /// Fired (main thread) when ESC is pressed AND a dictation session is active (see ``isSessionActive``). The coordinator wires this to its cancel path.
    public var onCancel: (() -> Void)?

    /// Queried on each ESC keyDown to decide whether a dictation is in progress; ESC is ignored (not consumed, and ``onCancel`` not fired) when this
    /// returns false / is nil, so we never swallow ESC globally — the foreground app keeps receiving it. The coordinator owns this state (its phase),
    /// keeping the "ignore ESC when idle" rule in one place rather than duplicating dictation state inside the manager.
    public var isSessionActive: (() -> Bool)?

    /// Fired (main thread) on EVERY keyDown while monitoring — a passive "the user typed a key" activity signal for the
    /// learn-from-edits feature, used by the coordinator to reset its idle timer (so the compare fires only after the user
    /// pauses). The monitor is observe-only: the key is NEVER consumed, so the foreground app still receives it and normal
    /// typing is never blocked. The coordinator ignores this unless a fresh injection record is armed, so it is harmless
    /// when nothing is pending. Fired BEFORE any early-return so even ESC / commit / edit keys count as activity.
    public var onUserKeystroke: (() -> Void)?

    /// Fired (main thread) on a Return / keypad-Enter keyDown — a "the user committed the edit" signal for the
    /// learn-from-edits feature. The coordinator reacts by firing its compare once. Observe-only: the key is NEVER
    /// consumed (the foreground app still receives the Return), and it returns early so it does not taint the single-tap
    /// candidate (same discipline as ESC). Harmless when nothing is armed (the coordinator ignores it then).
    public var onCommitKey: (() -> Void)?

    /// Fired (main thread) on a Backspace / Forward-Delete keyDown — a "the user actually EDITED the text" signal for the
    /// learn-from-edits feature. The coordinator uses this to require that a real correction happened before a compare can
    /// fire (the commit / focus-loss / idle signals still decide WHEN). Observe-only: the key is NEVER consumed (the
    /// foreground app still receives the delete), and it returns early so it does not taint the single-tap candidate (same
    /// discipline as ESC). Harmless when nothing is armed (the coordinator ignores it then).
    public var onEditKey: (() -> Void)?

    /// Event async sequence, convenient for `for await event in manager.events { ... }`.
    public let events: AsyncStream<HotkeyEvent>
    private let eventContinuation: AsyncStream<HotkeyEvent>.Continuation

    // MARK: Internal state

    private var holdMachine = HoldStateMachine()
    private var singleTapMachine: SingleTapToggleStateMachine

    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    /// Whether monitoring is active.
    public private(set) var isRunning = false

    // MARK: Initialization

    /// - Parameters:
    ///   - triggerKey: the trigger key, defaults to the right Command.
    ///   - mode: the trigger mode, defaults to single-tap toggle.
    ///   - singleTapWindow: the single-tap isolated-tap down -> up window (seconds), defaults to 0.3.
    public init(
        triggerKey: TriggerKey = .default,
        mode: HotkeyMode = .singleTapToggle,
        singleTapWindow: TimeInterval = 0.3
    ) {
        self.triggerKey = triggerKey
        self.mode = mode
        self.singleTapWindow = singleTapWindow
        self.singleTapMachine = SingleTapToggleStateMachine(window: singleTapWindow)

        var continuation: AsyncStream<HotkeyEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: Permissions

    /// Whether the process has been granted Accessibility trust (a prerequisite for global keyboard monitoring).
    ///
    /// When it returns `false`, the user should be guided to System Settings > Privacy & Security > Accessibility to check this app,
    /// otherwise global monitoring can be established but receives no events.
    public static var isProcessTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Same as above, an instance convenience accessor.
    public var isProcessTrusted: Bool { Self.isProcessTrusted }

    // MARK: Start/stop

    /// Start global monitoring. Repeated calls are idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        resetStateMachines()

        // The trigger key is a modifier; its down/up goes through .flagsChanged.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
        }
        // An ordinary key's keyDown is used to taint the single-tap candidate (a shortcut in between does not trigger).
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyDown(event) }
        }
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyUp(event) }
        }
    }

    /// Stop monitoring and remove all system monitors. Repeated calls are idempotent.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        for monitor in [flagsMonitor, keyDownMonitor, keyUpMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        flagsMonitor = nil
        keyDownMonitor = nil
        keyUpMonitor = nil
        resetStateMachines()
    }

    // MARK: External session lifecycle

    /// Notifies the manager that the dictation session ended **externally** — i.e. without a second trigger tap — such as an
    /// ESC-cancel or a recording start-failure. In single-tap-toggle mode this resynchronizes the toggle: the state machine's
    /// `isActive` flag is the SOLE start/stop driver, and if it is left `active` after such an end the user's NEXT tap emits a
    /// phantom `.stop` against an already-idle coordinator and is silently wasted (forcing a double tap to resume). Forcing it
    /// back to inactive makes the next tap a clean `.start`.
    ///
    /// Hold-to-talk mode has no toggle (start/stop are driven by the physical key down/up), so this is a no-op there.
    public func sessionDidEndExternally() {
        singleTapMachine.deactivate()
    }

    /// Whether the single-tap-toggle state machine currently considers a session active (so its next isolated tap would
    /// emit `.stop`). Exposed for tests to assert ``sessionDidEndExternally()`` resynced the toggle after an external end.
    public var _test_singleTapSessionActive: Bool { singleTapMachine.isSessionActive }

    /// Drives one isolated tap through the single-tap-toggle state machine, flipping its toggle (returns the emitted
    /// event). Tests use this to put the toggle in the "active" state a real first `.start` tap would produce, since
    /// NSEvent global monitoring cannot be synthesized in unit tests.
    @discardableResult
    public func _test_emitSingleTap() -> HotkeyEvent? {
        singleTapMachine.modifierDown(at: 0)
        return singleTapMachine.modifierUp(at: 0)
    }

    /// Synthesizes one ordinary keyDown by virtual keyCode and runs it through the SAME private ``handleKeyDown(_:)``
    /// path a real global monitor would (NSEvent global monitoring cannot be synthesized in unit tests). Used to assert
    /// every keyDown fires ``onUserKeystroke``, Return(36)/keypad-Enter(76) fire ``onCommitKey``, and that commit/edit
    /// keys do not disturb the single-tap candidate. Returns the constructed event so callers can also reuse it; a `nil`
    /// return means the platform refused to build the synthetic event (treated as a skipped assertion by the test).
    @discardableResult
    public func _test_emitKeyDown(keyCode: UInt16) -> NSEvent? {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else { return nil }
        handleKeyDown(event)
        return event
    }

    // MARK: Event handling (shell layer -> pure state machine)

    private func handleFlagsChanged(_ event: NSEvent) {
        let key = triggerKey

        switch mode {
        case .singleTapToggle:
            handleSingleTapFlagsChanged(event, key: key)

        case .holdToTalk:
            handleHoldFlagsChanged(event, key: key)
        }
    }

    /// In single-tap mode, the trigger key's down/up goes through `.flagsChanged` (modifier keys do not send keyDown/keyUp).
    /// Down begins a candidate tap; on up the state machine decides whether it constitutes an isolated tap (an ordinary key in between is tainted by `handleKeyDown`).
    private func handleSingleTapFlagsChanged(_ event: NSEvent, key: TriggerKey) {
        if isTriggerPressEdge(event, key: key) {
            singleTapMachine.modifierDown(at: event.timestamp)
        } else if key == .fnGlobe || event.keyCode == key.keyCode {
            // The release edge of the target key (the flag is cleared).
            if let result = singleTapMachine.modifierUp(at: event.timestamp) {
                emit(result)
            }
        } else {
            // Another modifier key down/up (e.g. Cmd+Option pressed together): treated as another key in between, voiding this candidate tap.
            singleTapMachine.otherKeyDown()
        }
    }

    /// Decides whether this `.flagsChanged` is the "down" edge of the trigger key (that key's modifier flag is set at this moment).
    /// Fn/Globe's physical keyCode is unstable, so for it we only compare the `.function` flag.
    private func isTriggerPressEdge(_ event: NSEvent, key: TriggerKey) -> Bool {
        key == .fnGlobe
            ? event.modifierFlags.contains(.function)
            : (event.keyCode == key.keyCode && event.modifierFlags.contains(key.modifierFlag))
    }

    /// In hold mode, if the trigger key itself is a modifier, its down/up goes through `.flagsChanged` (modifier keys do not send keyDown/keyUp).
    private func handleHoldFlagsChanged(_ event: NSEvent, key: TriggerKey) {
        let isPressed: Bool = key == .fnGlobe
            ? event.modifierFlags.contains(.function)
            : (event.keyCode == key.keyCode && event.modifierFlags.contains(key.modifierFlag))

        if isPressed {
            if let result = holdMachine.keyDown() { emit(result) }
        } else if key == .fnGlobe || event.keyCode == key.keyCode {
            // The release edge of the target key (the flag is cleared).
            if let result = holdMachine.keyUp() { emit(result) }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Learn-from-edits activity signal: EVERY keyDown counts as a keystroke (so the coordinator can reset its idle
        // timer). Fired first, before any early-return, so ESC / commit / edit keys also count as activity. Observe-only.
        onUserKeystroke?()

        if event.keyCode == escapeKeyCode {
            // ESC cancels an in-progress dictation only. When idle (isSessionActive false/nil) we do nothing and leave ESC to the foreground app,
            // and return early so ESC never taints the single-tap candidate (otherwise a stray ESC during a hold could void the tap).
            if isSessionActive?() == true { onCancel?() }
            return
        }

        if event.keyCode == returnKeyCode || event.keyCode == keypadEnterKeyCode {
            // Commit signal for learn-from-edits: notify (never consume) and return early so the commit key does not taint
            // the single-tap candidate (same reasoning as ESC). The coordinator ignores this unless a fresh injection
            // record is armed, so normal typing is never affected.
            onCommitKey?()
            return
        }

        if event.keyCode == backspaceKeyCode || event.keyCode == forwardDeleteKeyCode {
            // Edit keys are observe-only: notify "a real edit happened" (the necessary signal that the user corrected
            // something) but NEVER consume, then return early so they do not taint the single-tap candidate (same reasoning
            // as ESC). They do not drive a compare directly — they only flip the coordinator's didEdit gate; the compare is
            // still commit/idle/focus-loss triggered. Harmless when nothing is armed (the coordinator ignores it then).
            onEditKey?()
            return
        }

        switch mode {
        case .singleTapToggle:
            // An ordinary key (e.g. Cmd-C) was pressed while the modifier was held: taint this candidate tap, release no longer triggers -> yield to the shortcut.
            singleTapMachine.otherKeyDown()
        case .holdToTalk:
            // When the trigger key is a modifier it is handled by .flagsChanged; here we only handle non-modifier trigger keys (reserved for extension).
            break
        }
    }

    private func handleKeyUp(_ event: NSEvent) {
        // The current trigger keys are all modifiers, release goes through .flagsChanged; an ordinary key's keyUp needs no handling for now (reserved for extension).
    }

    // MARK: Utilities

    private func emit(_ event: HotkeyEvent) {
        onEvent?(event)
        eventContinuation.yield(event)
    }

    private func resetStateMachines() {
        holdMachine.reset()
        singleTapMachine.reset()
    }
}
