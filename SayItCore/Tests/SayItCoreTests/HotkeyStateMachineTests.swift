import XCTest
@testable import SayItCore

/// 纯状态机单测：覆盖「双击判定」与「按住判定」的时间阈值与事件序列。
/// 这些类型不依赖任何系统事件监听，可在 CI 上确定性运行。
final class HotkeyStateMachineTests: XCTestCase {

    // MARK: - DoubleTapDetector（toggle 模式的双击起停）

    func testDoubleTapWithinThresholdFires() {
        var detector = DoubleTapDetector(threshold: 0.4)
        XCTAssertFalse(detector.registerPress(at: 0.0), "首次按下不应触发")
        XCTAssertTrue(detector.registerPress(at: 0.3), "阈值内的第二次按下应触发")
    }

    func testDoubleTapAtExactThresholdFires() {
        var detector = DoubleTapDetector(threshold: 0.4)
        XCTAssertFalse(detector.registerPress(at: 1.0))
        // 间隔恰好等于阈值：按 <= 判定，应触发（边界含端点）。
        XCTAssertTrue(detector.registerPress(at: 1.4))
    }

    func testDoubleTapBeyondThresholdDoesNotFire() {
        var detector = DoubleTapDetector(threshold: 0.4)
        XCTAssertFalse(detector.registerPress(at: 0.0))
        // 超过阈值：第二次按下被当作「新的首次按下」，不触发。
        XCTAssertFalse(detector.registerPress(at: 0.5))
    }

    func testThirdPressAfterDoubleTapStartsFresh() {
        var detector = DoubleTapDetector(threshold: 0.4)
        XCTAssertFalse(detector.registerPress(at: 0.0))
        XCTAssertTrue(detector.registerPress(at: 0.2), "第二次触发")
        // 触发后内部状态清空，第三次按下又是「首次」。
        XCTAssertFalse(detector.registerPress(at: 0.3))
        XCTAssertTrue(detector.registerPress(at: 0.4), "第四次按下完成新的一对双击")
    }

    func testResetClearsPendingPress() {
        var detector = DoubleTapDetector(threshold: 0.4)
        XCTAssertFalse(detector.registerPress(at: 0.0))
        detector.reset()
        // reset 后此前的首次按下作废，紧接着的按下不应触发。
        XCTAssertFalse(detector.registerPress(at: 0.1))
    }

    // MARK: - ToggleStateMachine（双击 -> start，再次双击 -> stop）

    func testToggleAlternatesStartStop() {
        var machine = ToggleStateMachine(threshold: 0.4)
        XCTAssertNil(machine.registerPress(at: 0.0))
        XCTAssertEqual(machine.registerPress(at: 0.2), .start, "首个双击开始")
        XCTAssertNil(machine.registerPress(at: 1.0))
        XCTAssertEqual(machine.registerPress(at: 1.2), .stop, "再次双击结束")
        XCTAssertNil(machine.registerPress(at: 2.0))
        XCTAssertEqual(machine.registerPress(at: 2.2), .start, "第三次双击重新开始")
    }

    func testToggleResetKeepsActiveState() {
        var machine = ToggleStateMachine(threshold: 0.4)
        XCTAssertNil(machine.registerPress(at: 0.0))
        XCTAssertEqual(machine.registerPress(at: 0.2), .start)
        // reset 仅打断「半个双击」，不改变 active/inactive 的会话状态。
        machine.reset()
        XCTAssertNil(machine.registerPress(at: 1.0))
        XCTAssertEqual(machine.registerPress(at: 1.2), .stop, "reset 后再次双击仍应结束")
    }

    // MARK: - HoldStateMachine（按住 -> start，松开 -> stop）

    func testHoldDownThenUpProducesStartStop() {
        var machine = HoldStateMachine()
        XCTAssertEqual(machine.keyDown(), .start)
        XCTAssertEqual(machine.keyUp(), .stop)
    }

    func testHoldRepeatedKeyDownDoesNotRestart() {
        var machine = HoldStateMachine()
        XCTAssertEqual(machine.keyDown(), .start)
        // 系统按键自动重复会发多次 keyDown，但不应重复触发 start。
        XCTAssertNil(machine.keyDown())
        XCTAssertNil(machine.keyDown())
        XCTAssertEqual(machine.keyUp(), .stop)
    }

    func testHoldKeyUpWithoutDownIsIgnored() {
        var machine = HoldStateMachine()
        // 没按下就松开（例如监听刚启动时残留的 up）应被忽略。
        XCTAssertNil(machine.keyUp())
    }

    func testHoldResetWhileHeldEmitsNothingButClearsState() {
        var machine = HoldStateMachine()
        XCTAssertEqual(machine.keyDown(), .start)
        machine.reset()
        // reset 后再次松开不应产生 stop（状态已清）。
        XCTAssertNil(machine.keyUp())
        // 且可以重新开始。
        XCTAssertEqual(machine.keyDown(), .start)
    }
}
