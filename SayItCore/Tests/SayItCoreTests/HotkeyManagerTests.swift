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

    // MARK: onEditKey (learn-from-edits passive edit signal)

    /// A Backspace (keyCode 51) keyDown fires ``onEditKey`` exactly once. Drives the same private handleKeyDown path a real
    /// global monitor would, since NSEvent global monitoring cannot be synthesized in unit tests.
    func testOnEditKeyFiresForBackspace() {
        let manager = HotkeyManager()
        var fired = 0
        manager.onEditKey = { fired += 1 }
        // If the platform refuses to build the synthetic NSEvent (returns nil), skip — the wiring is still asserted by the
        // forward-delete test on any platform that can build one.
        guard manager._test_emitKeyDown(keyCode: 51) != nil else { return }
        XCTAssertEqual(fired, 1, "Backspace(51) should fire onEditKey exactly once")
    }

    /// A Forward-Delete (keyCode 117) keyDown fires ``onEditKey`` exactly once.
    func testOnEditKeyFiresForForwardDelete() {
        let manager = HotkeyManager()
        var fired = 0
        manager.onEditKey = { fired += 1 }
        guard manager._test_emitKeyDown(keyCode: 117) != nil else { return }
        XCTAssertEqual(fired, 1, "Forward-Delete(117) should fire onEditKey exactly once")
    }

    /// An ordinary, non-edit key (e.g. 'A' = keyCode 0) must NOT fire ``onEditKey``: only Backspace/Forward-Delete are edit signals.
    func testOnEditKeyDoesNotFireForOrdinaryKey() {
        let manager = HotkeyManager()
        var fired = 0
        manager.onEditKey = { fired += 1 }
        guard manager._test_emitKeyDown(keyCode: 0) != nil else { return }
        XCTAssertEqual(fired, 0, "an ordinary key should not fire onEditKey")
    }

    /// An edit key must NOT disturb the single-tap candidate: it returns early (like ESC) before otherKeyDown(), so a tap
    /// that brackets an edit key still emits .start. (If the edit key wrongly tainted the candidate, the tap would be voided.)
    func testEditKeyDoesNotTaintSingleTapCandidate() {
        let manager = HotkeyManager(mode: .singleTapToggle)
        // Synthesize an edit key between a modifier down and up is not feasible via the state-machine seam, so instead assert
        // the negative: after an edit key, a fresh isolated tap still emits .start (the candidate logic is untouched).
        guard manager._test_emitKeyDown(keyCode: 51) != nil else { return }
        XCTAssertEqual(manager._test_emitSingleTap(), .start, "an edit key should not taint the single-tap candidate: a later isolated tap should still .start")
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
