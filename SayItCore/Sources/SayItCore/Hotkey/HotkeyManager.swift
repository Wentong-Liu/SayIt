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

    // MARK: Event output

    /// Main-thread event callback (active simultaneously with ``events``).
    public var onEvent: ((HotkeyEvent) -> Void)?

    /// Fired (main thread) when ESC is pressed AND a dictation session is active (see ``isSessionActive``). The coordinator wires this to its cancel path.
    public var onCancel: (() -> Void)?

    /// Queried on each ESC keyDown to decide whether a dictation is in progress; ESC is ignored (not consumed, and ``onCancel`` not fired) when this
    /// returns false / is nil, so we never swallow ESC globally — the foreground app keeps receiving it. The coordinator owns this state (its phase),
    /// keeping the "ignore ESC when idle" rule in one place rather than duplicating dictation state inside the manager.
    public var isSessionActive: (() -> Bool)?

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
        if event.keyCode == escapeKeyCode {
            // ESC cancels an in-progress dictation only. When idle (isSessionActive false/nil) we do nothing and leave ESC to the foreground app,
            // and return early so ESC never taints the single-tap candidate (otherwise a stray ESC during a hold could void the tap).
            if isSessionActive?() == true { onCancel?() }
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
