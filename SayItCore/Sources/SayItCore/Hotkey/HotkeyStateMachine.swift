import Foundation

/// The edge events of a dictation session, produced by the hotkey state machine and passed upward.
public enum HotkeyEvent: Equatable, Sendable {
    /// Start recording/dictation.
    case start
    /// End recording/dictation.
    case stop
}

/// Trigger mode.
public enum HotkeyMode: String, CaseIterable, Sendable {
    /// Hold the trigger key to speak: keyDown -> start, keyUp -> stop.
    case holdToTalk
    /// Tap (isolated tap) the modifier key to start, tap again to end.
    ///
    /// An "isolated tap" = after the modifier key goes down, **no ordinary key is pressed in between**, and it is released within a short window (see ``IsolatedTapDetector``).
    /// This keeps the tap trigger from conflicting with ordinary shortcuts (e.g. Cmd-C). Corresponds to the Typeless / Shandianshuo interaction.
    case singleTapToggle
}

// MARK: - hold-to-talk mode state machine (pure logic)

/// hold-to-talk mode: press the trigger key -> start, release -> stop.
///
/// Handles system key auto-repeat (consecutive keyDowns) and abnormal sequences (an up with no down).
public struct HoldStateMachine: Sendable {
    /// Whether currently in the "held" state.
    private var isHeld = false

    public init() {}

    /// Registers a trigger-key "down".
    /// - Returns: `.start` on the transition from not-held to held; nil for subsequent auto-repeat keyDowns.
    public mutating func keyDown() -> HotkeyEvent? {
        guard !isHeld else { return nil }
        isHeld = true
        return .start
    }

    /// Registers a trigger-key "up".
    /// - Returns: `.stop` on the transition from held to released; nil when not in the held state.
    public mutating func keyUp() -> HotkeyEvent? {
        guard isHeld else { return nil }
        isHeld = false
        return .stop
    }

    /// Clears the held state and produces no event (e.g. forced reset on monitor restart or focus loss).
    public mutating func reset() {
        isHeld = false
    }
}

// MARK: - isolated tap detection (pure logic)

/// A pure state machine for "isolated tap" detection: recognizes a single **standalone** modifier-key tap.
///
/// Trigger conditions (all three required):
/// 1. the modifier key goes down (`modifierDown`) then up (`modifierUp`);
/// 2. during this **no ordinary (non-modifier) key** is pressed -- otherwise it is a key combination (e.g. Cmd-C), not a tap;
/// 3. the down-to-up interval is <= ``window`` (default ~0.3s) -- a long press is not a tap (left to hold mode, or to avoid accidental touches).
///
/// This is exactly the standard approach of Typeless (tap Option) / Shandianshuo (tap Command), letting tap triggers coexist with system shortcuts:
/// when another key is in between it is treated as an ordinary shortcut and let through, not triggering dictation.
///
/// Does not depend on a clock -- the caller passes in event timestamps (e.g. `NSEvent.timestamp`, in seconds), so unit tests can cover window boundaries with
/// deterministic time sequences.
public struct IsolatedTapDetector: Sendable {
    /// The maximum down-to-up interval (seconds, inclusive) judged as a "tap". Beyond this it is treated as a long press, not a tap.
    public let window: TimeInterval

    /// The timestamp of the modifier-key down; nil means the modifier key is not currently down (no candidate tap in progress).
    private var pressTimestamp: TimeInterval?
    /// Whether this hold was tainted by an "ordinary key in between" (once tainted, the release is not judged a tap).
    private var contaminated = false

    /// - Parameter window: the tap time window (seconds), defaults to 0.3s.
    public init(window: TimeInterval = 0.3) {
        self.window = window
    }

    /// Registers the modifier-key "down" edge, beginning a candidate tap.
    ///
    /// Auto-repeat (the system does not repeatedly send flagsChanged while a modifier is held, but just in case): if already down, ignore,
    /// preserving the first down's timestamp and taint state.
    public mutating func modifierDown(at timestamp: TimeInterval) {
        guard pressTimestamp == nil else { return }
        pressTimestamp = timestamp
        contaminated = false
    }

    /// Registers the modifier-key "up" edge.
    /// - Returns: `true` when the three isolated-tap conditions are met (and resets, recounting next time); otherwise `false`.
    public mutating func modifierUp(at timestamp: TimeInterval) -> Bool {
        defer { reset() }
        guard let press = pressTimestamp, !contaminated else { return false }
        return timestamp - press <= window
    }

    /// Registers one ordinary (non-modifier) key press, tainting the current candidate tap (so the later release is no longer judged a tap).
    /// Only meaningful while the modifier key is down; calling it when not down has no side effect.
    public mutating func otherKeyDown() {
        guard pressTimestamp != nil else { return }
        contaminated = true
    }

    /// Reset: voids the in-progress candidate tap (e.g. on monitor restart or focus loss).
    public mutating func reset() {
        pressTimestamp = nil
        contaminated = false
    }
}

// MARK: - single-tap toggle state machine (pure logic)

/// single-tap-to-toggle mode: one isolated tap -> start, another -> stop, alternating.
///
/// Maintains a "session active (recording)" toggle on top of ``IsolatedTapDetector``.
public struct SingleTapToggleStateMachine: Sendable {
    private var detector: IsolatedTapDetector
    /// Whether the session is in the active (recording) state.
    private var isActive = false

    /// - Parameter window: the tap time window (seconds), defaults to 0.3s.
    public init(window: TimeInterval = 0.3) {
        self.detector = IsolatedTapDetector(window: window)
    }

    /// Registers the modifier-key down edge (beginning a candidate tap). Produces no event itself.
    public mutating func modifierDown(at timestamp: TimeInterval) {
        detector.modifierDown(at: timestamp)
    }

    /// Registers the modifier-key up edge.
    /// - Returns: `.start` / `.stop` (alternating) when an isolated tap is formed; otherwise nil.
    public mutating func modifierUp(at timestamp: TimeInterval) -> HotkeyEvent? {
        guard detector.modifierUp(at: timestamp) else { return nil }
        isActive.toggle()
        return isActive ? .start : .stop
    }

    /// Ordinary key press: taints the current candidate tap (the later release does not trigger), without changing the session active state.
    public mutating func otherKeyDown() {
        detector.otherKeyDown()
    }

    /// Resets the in-progress candidate tap; does not change the session active state.
    public mutating func reset() {
        detector.reset()
    }
}
