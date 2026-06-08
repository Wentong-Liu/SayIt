import XCTest
@testable import SayItCore

/// Pure state-machine unit test: covers the time thresholds and event sequences of "isolated tap detection" and "hold detection".
/// These types depend on no system event monitoring and can run deterministically on CI.
final class HotkeyStateMachineTests: XCTestCase {

    // MARK: - HoldStateMachine (hold -> start, release -> stop)

    func testHoldDownThenUpProducesStartStop() {
        var machine = HoldStateMachine()
        XCTAssertEqual(machine.keyDown(), .start)
        XCTAssertEqual(machine.keyUp(), .stop)
    }

    func testHoldRepeatedKeyDownDoesNotRestart() {
        var machine = HoldStateMachine()
        XCTAssertEqual(machine.keyDown(), .start)
        // System key auto-repeat sends multiple keyDowns, but should not trigger start repeatedly.
        XCTAssertNil(machine.keyDown())
        XCTAssertNil(machine.keyDown())
        XCTAssertEqual(machine.keyUp(), .stop)
    }

    func testHoldKeyUpWithoutDownIsIgnored() {
        var machine = HoldStateMachine()
        // A release without a press (e.g. a leftover up right after monitoring starts) should be ignored.
        XCTAssertNil(machine.keyUp())
    }

    func testHoldResetWhileHeldEmitsNothingButClearsState() {
        var machine = HoldStateMachine()
        XCTAssertEqual(machine.keyDown(), .start)
        machine.reset()
        // After reset, releasing again should not produce stop (the state is cleared).
        XCTAssertNil(machine.keyUp())
        // And it can start again.
        XCTAssertEqual(machine.keyDown(), .start)
    }

    // MARK: - IsolatedTapDetector (isolated tap: the core decision for tap triggering)

    func testIsolatedTapWithinWindowFires() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        // The down -> up interval within the window with no ordinary key in between -> it is an isolated tap.
        XCTAssertTrue(detector.modifierUp(at: 0.1))
    }

    func testIsolatedTapAtExactWindowFires() {
        var detector = IsolatedTapDetector(window: 0.5)
        detector.modifierDown(at: 1.0)
        // The interval exactly equal to the window (<= decision, inclusive) -> triggers. Uses a precisely-representable binary fraction to avoid float error.
        XCTAssertTrue(detector.modifierUp(at: 1.5))
    }

    func testIsolatedTapBeyondWindowDoesNotFire() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        // A long press exceeding the window -> not a tap.
        XCTAssertFalse(detector.modifierUp(at: 0.5))
    }

    func testChordWithOtherKeyDoesNotFire() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        // An ordinary key (e.g. Cmd-C) pressed during the hold -> tainted -> release does not trigger, yielding to the shortcut.
        detector.otherKeyDown()
        XCTAssertFalse(detector.modifierUp(at: 0.1))
    }

    func testOtherKeyBeforeModifierDownIsIgnored() {
        var detector = IsolatedTapDetector(window: 0.3)
        // An ordinary key press while the modifier is not down should not taint the next tap.
        detector.otherKeyDown()
        detector.modifierDown(at: 0.0)
        XCTAssertTrue(detector.modifierUp(at: 0.1))
    }

    func testIsolatedTapUpWithoutDownIsIgnored() {
        var detector = IsolatedTapDetector(window: 0.3)
        // A release without a press (a monitoring-start leftover) should be ignored, not triggering.
        XCTAssertFalse(detector.modifierUp(at: 0.1))
    }

    func testIsolatedTapResetsBetweenTaps() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        XCTAssertTrue(detector.modifierUp(at: 0.1), "first tap")
        // The state is reset: a second complete tap should still trigger.
        detector.modifierDown(at: 1.0)
        XCTAssertTrue(detector.modifierUp(at: 1.1), "second tap")
    }

    func testIsolatedTapContaminationClearsAfterUp() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        detector.otherKeyDown()
        XCTAssertFalse(detector.modifierUp(at: 0.1), "this chorded tap does not fire")
        // The taint resets on release: the next clean tap should trigger.
        detector.modifierDown(at: 1.0)
        XCTAssertTrue(detector.modifierUp(at: 1.05))
    }

    func testIsolatedTapDownIsIdempotentKeepsFirstTimestamp() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        // A repeated down edge should not refresh the start point (a safeguard against auto-repeat).
        detector.modifierDown(at: 0.25)
        // Counting from the first 0.0: by 0.4 the window is already exceeded -> does not trigger.
        XCTAssertFalse(detector.modifierUp(at: 0.4))
    }

    // MARK: - SingleTapToggleStateMachine (isolated tap -> start, again -> stop)

    func testSingleTapToggleAlternatesStartStop() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.modifierDown(at: 0.0)
        XCTAssertEqual(machine.modifierUp(at: 0.1), .start, "the first isolated tap starts")
        machine.modifierDown(at: 1.0)
        XCTAssertEqual(machine.modifierUp(at: 1.1), .stop, "another tap stops")
        machine.modifierDown(at: 2.0)
        XCTAssertEqual(machine.modifierUp(at: 2.1), .start, "the third tap starts again")
    }

    func testSingleTapToggleChordDoesNotToggle() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.modifierDown(at: 0.0)
        machine.otherKeyDown()
        // An ordinary key (shortcut) in between -> does not trigger, the session state is unchanged.
        XCTAssertNil(machine.modifierUp(at: 0.1))
        // Afterwards one clean tap should start normally (proving the session is still inactive).
        machine.modifierDown(at: 1.0)
        XCTAssertEqual(machine.modifierUp(at: 1.1), .start)
    }

    func testSingleTapToggleLongPressDoesNotToggle() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.modifierDown(at: 0.0)
        // A long press exceeding the window does not trigger.
        XCTAssertNil(machine.modifierUp(at: 0.6))
    }

    func testSingleTapToggleResetDoesNotChangeActiveState() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.modifierDown(at: 0.0)
        XCTAssertEqual(machine.modifierUp(at: 0.1), .start)
        // reset only voids the in-progress candidate tap, not changing the "already active" session.
        machine.modifierDown(at: 1.0)
        machine.reset()
        // After reset, releasing does not trigger (the candidate is voided).
        XCTAssertNil(machine.modifierUp(at: 1.05))
        // The next clean tap should give .stop (the session is still active).
        machine.modifierDown(at: 2.0)
        XCTAssertEqual(machine.modifierUp(at: 2.1), .stop)
    }

    // MARK: - SingleTapToggle deactivate (session ended externally: ESC-cancel / start-failure)

    /// Regression guard (single-tap toggle desync on external session end): in single-tap-toggle mode the `isActive`
    /// flag is the SOLE start/stop driver. When the session ends WITHOUT a second tap (ESC-cancel or a start-failure),
    /// `isActive` must be forced back to inactive — otherwise the user's NEXT tap emits `.stop` against an already-idle
    /// coordinator (isRecording==false) and is silently wasted, forcing a double tap to resume.
    /// After `deactivate()`, the next clean tap must emit `.start` (a new session), NOT `.stop`.
    func testSingleTapToggleDeactivateResetsActiveSoNextTapStarts() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        // 1) First isolated tap activates the session (-> .start).
        machine.modifierDown(at: 0.0)
        XCTAssertEqual(machine.modifierUp(at: 0.1), .start)
        // 2) Session ends externally (ESC-cancel / start-failure): force the toggle back to inactive.
        machine.deactivate()
        // 3) The NEXT clean tap must START a fresh session again (not be wasted as a phantom .stop).
        machine.modifierDown(at: 1.0)
        XCTAssertEqual(machine.modifierUp(at: 1.1), .start,
                       "after the session ends externally, the next tap should .start again (instead of being swallowed as an invalid .stop)")
    }

    /// `deactivate()` on an already-inactive machine is a harmless no-op: the first tap still starts as normal.
    func testSingleTapToggleDeactivateWhenInactiveIsNoOp() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.deactivate()
        machine.modifierDown(at: 0.0)
        XCTAssertEqual(machine.modifierUp(at: 0.1), .start, "when inactive, deactivate should be a no-op and the first tap starts normally")
    }

    /// `deactivate()` also voids any in-progress candidate tap (consistent with `reset()`), so a half-completed tap
    /// straddling the external end does not later resolve into a stray event.
    func testSingleTapToggleDeactivateVoidsInProgressCandidate() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.modifierDown(at: 0.0)
        XCTAssertEqual(machine.modifierUp(at: 0.1), .start)
        // A new candidate tap begins, then the session ends externally before release.
        machine.modifierDown(at: 1.0)
        machine.deactivate()
        // The straddling release must NOT trigger (the candidate was voided).
        XCTAssertNil(machine.modifierUp(at: 1.05), "deactivate should void the in-progress candidate tap")
        // And the next clean tap starts a fresh session.
        machine.modifierDown(at: 2.0)
        XCTAssertEqual(machine.modifierUp(at: 2.1), .start)
    }
}
