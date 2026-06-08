import XCTest
@testable import SayItCore

/// The testable surface of the HotkeyManager shell layer: config default values and the start/stop lifecycle (idempotency, the isRunning flag).
/// Real global event injection is out of unit-test scope -- its decision logic is already covered by the pure state-machine tests.
@MainActor
final class HotkeyManagerTests: XCTestCase {

    func testDefaultConfiguration() {
        let manager = HotkeyManager()
        XCTAssertEqual(manager.triggerKey, .rightCommand)
        XCTAssertEqual(manager.mode, .singleTapToggle, "默认应为单击切换（孤立轻点）")
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
