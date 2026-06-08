import XCTest
@testable import SayItCore

/// The testable surface of the HotkeyManager shell layer: config default values and the start/stop lifecycle (idempotency, the isRunning flag).
/// Real global event injection is out of unit-test scope -- its decision logic is already covered by the pure state-machine tests.
@MainActor
final class HotkeyManagerTests: XCTestCase {

    func testDefaultConfiguration() {
        let manager = HotkeyManager()
        XCTAssertEqual(manager.triggerKey, .rightCommand)
        XCTAssertEqual(manager.mode, .singleTapToggle, "the default should be single-tap toggle (isolated tap)")
        XCTAssertEqual(manager.singleTapWindow, 0.3, accuracy: 0.0001)
        XCTAssertFalse(manager.isRunning)
    }

    func testCustomConfiguration() {
        let manager = HotkeyManager(triggerKey: .fnGlobe, mode: .holdToTalk, singleTapWindow: 0.25)
        XCTAssertEqual(manager.triggerKey, .fnGlobe)
        XCTAssertEqual(manager.mode, .holdToTalk)
        XCTAssertEqual(manager.singleTapWindow, 0.25, accuracy: 0.0001)
    }

    func testStartStopTogglesIsRunning() {
        let manager = HotkeyManager()
        manager.start()
        XCTAssertTrue(manager.isRunning)
        manager.stop()
        XCTAssertFalse(manager.isRunning)
    }

    func testStartIsIdempotent() {
        let manager = HotkeyManager()
        manager.start()
        manager.start()
        XCTAssertTrue(manager.isRunning)
        manager.stop()
        XCTAssertFalse(manager.isRunning)
    }

    func testStopWithoutStartIsSafe() {
        let manager = HotkeyManager()
        manager.stop()
        XCTAssertFalse(manager.isRunning)
    }

    func testModeCanBeChangedAtRuntime() {
        let manager = HotkeyManager(mode: .holdToTalk)
        manager.mode = .singleTapToggle
        XCTAssertEqual(manager.mode, .singleTapToggle)
        manager.triggerKey = .leftOption
        XCTAssertEqual(manager.triggerKey, .leftOption)
    }

    func testIsProcessTrustedIsQueryable() {
        // Only verify it can be called and returns a bool (the CI environment is usually unauthorized -> false).
        let manager = HotkeyManager()
        _ = manager.isProcessTrusted
        _ = HotkeyManager.isProcessTrusted
    }

    // MARK: onUserKeystroke / onCommitKey (learn-from-edits v2 activity + commit signals)

    /// EVERY keyDown fires ``onUserKeystroke`` exactly once (the idle-timer reset signal). Drives the same private
    /// handleKeyDown path a real global monitor would, since NSEvent global monitoring cannot be synthesized in unit tests.
    func testOnUserKeystrokeFiresForOrdinaryKey() {
        let manager = HotkeyManager()
        var fired = 0
        manager.onUserKeystroke = { fired += 1 }
        // If the platform refuses to build the synthetic NSEvent (returns nil), skip.
        guard manager._test_emitKeyDown(keyCode: 0) != nil else { return }
        XCTAssertEqual(fired, 1, "an ordinary keyDown should fire onUserKeystroke exactly once")
    }

    /// Even the commit / edit keys count as keystrokes: ``onUserKeystroke`` fires first (before the early-return), so a
    /// Return(36) still bumps the activity signal.
    func testOnUserKeystrokeFiresForCommitKey() {
        let manager = HotkeyManager()
        var fired = 0
        manager.onUserKeystroke = { fired += 1 }
        guard manager._test_emitKeyDown(keyCode: 36) != nil else { return }
        XCTAssertEqual(fired, 1, "even a commit key should fire onUserKeystroke (it is still a keystroke)")
    }

    /// A Return (keyCode 36) keyDown fires ``onCommitKey`` exactly once. The compare-commit signal.
    func testOnCommitKeyFiresForReturn() {
        let manager = HotkeyManager()
        var fired = 0
        manager.onCommitKey = { fired += 1 }
        guard manager._test_emitKeyDown(keyCode: 36) != nil else { return }
        XCTAssertEqual(fired, 1, "Return(36) should fire onCommitKey exactly once")
    }

    /// A keypad Enter (keyCode 76) keyDown fires ``onCommitKey`` exactly once.
    func testOnCommitKeyFiresForKeypadEnter() {
        let manager = HotkeyManager()
        var fired = 0
        manager.onCommitKey = { fired += 1 }
        guard manager._test_emitKeyDown(keyCode: 76) != nil else { return }
        XCTAssertEqual(fired, 1, "keypad-Enter(76) should fire onCommitKey exactly once")
    }

    /// An ordinary, non-commit key (e.g. 'A' = keyCode 0) must NOT fire ``onCommitKey``: only Return/keypad-Enter commit.
    func testOnCommitKeyDoesNotFireForOrdinaryKey() {
        let manager = HotkeyManager()
        var fired = 0
        manager.onCommitKey = { fired += 1 }
        guard manager._test_emitKeyDown(keyCode: 0) != nil else { return }
        XCTAssertEqual(fired, 0, "an ordinary key should not fire onCommitKey")
    }

    /// A commit key must NOT disturb the single-tap candidate: it returns early (like ESC) before otherKeyDown(), so a tap
    /// that brackets a commit key still emits .start. (If the commit key wrongly tainted the candidate, the tap would be voided.)
    func testCommitKeyDoesNotTaintSingleTapCandidate() {
        let manager = HotkeyManager(mode: .singleTapToggle)
        // Synthesize a commit key between a modifier down and up is not feasible via the state-machine seam, so instead
        // assert the negative: after a commit key, a fresh isolated tap still emits .start (the candidate logic is untouched).
        guard manager._test_emitKeyDown(keyCode: 36) != nil else { return }
        XCTAssertEqual(manager._test_emitSingleTap(), .start, "a commit key should not taint the single-tap candidate: a later isolated tap should still .start")
    }

    /// The global keystroke monitor must never block normal typing: an ordinary keyDown returns (it does not consume the
    /// event), and a later isolated tap still emits .start. (No event is consumed; observe-only is preserved.)
    func testOrdinaryKeyDoesNotBlockTyping() {
        let manager = HotkeyManager(mode: .singleTapToggle)
        guard manager._test_emitKeyDown(keyCode: 0) != nil else { return }
        XCTAssertEqual(manager._test_emitSingleTap(), .start, "an ordinary keyDown must not block normal typing / single-tap")
    }

    /// `sessionDidEndExternally()` is safe to call in both modes and at any time (idle / running). The single-tap-toggle
    /// resync logic itself is covered deterministically by the pure SingleTapToggleStateMachine.deactivate() tests; here
    /// we only assert the manager surface does not crash and leaves the mode unchanged in either configuration.
    func testSessionDidEndExternallyIsSafeInBothModes() {
        let singleTap = HotkeyManager(mode: .singleTapToggle)
        singleTap.sessionDidEndExternally()  // idle, never started
        singleTap.start()
        singleTap.sessionDidEndExternally()  // running
        XCTAssertEqual(singleTap.mode, .singleTapToggle)
        singleTap.stop()

        let hold = HotkeyManager(mode: .holdToTalk)
        hold.sessionDidEndExternally()  // hold mode: no-op, must not affect the hold key tracking
        XCTAssertEqual(hold.mode, .holdToTalk)
    }
}
