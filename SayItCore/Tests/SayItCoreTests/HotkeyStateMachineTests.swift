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

    // MARK: - IsolatedTapDetector（孤立轻点：单击触发的核心判定）

    func testIsolatedTapWithinWindowFires() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        // 按下→松开间隔在窗口内、中途没夹普通键 -> 是孤立轻点。
        XCTAssertTrue(detector.modifierUp(at: 0.1))
    }

    func testIsolatedTapAtExactWindowFires() {
        var detector = IsolatedTapDetector(window: 0.5)
        detector.modifierDown(at: 1.0)
        // 间隔恰好等于窗口（<= 判定，含端点）-> 触发。用可精确表示的二进制小数避开浮点误差。
        XCTAssertTrue(detector.modifierUp(at: 1.5))
    }

    func testIsolatedTapBeyondWindowDoesNotFire() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        // 长按超过窗口 -> 不算轻点。
        XCTAssertFalse(detector.modifierUp(at: 0.5))
    }

    func testChordWithOtherKeyDoesNotFire() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        // 按住期间夹了普通键（如 ⌘C）-> 污染 -> 松开不触发，让位给快捷键。
        detector.otherKeyDown()
        XCTAssertFalse(detector.modifierUp(at: 0.1))
    }

    func testOtherKeyBeforeModifierDownIsIgnored() {
        var detector = IsolatedTapDetector(window: 0.3)
        // 修饰键未按下时的普通键按下不应污染下一次轻点。
        detector.otherKeyDown()
        detector.modifierDown(at: 0.0)
        XCTAssertTrue(detector.modifierUp(at: 0.1))
    }

    func testIsolatedTapUpWithoutDownIsIgnored() {
        var detector = IsolatedTapDetector(window: 0.3)
        // 没按下就松开（监听启动残留）应被忽略，不触发。
        XCTAssertFalse(detector.modifierUp(at: 0.1))
    }

    func testIsolatedTapResetsBetweenTaps() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        XCTAssertTrue(detector.modifierUp(at: 0.1), "第一次轻点")
        // 状态已复位：第二次完整轻点仍应触发。
        detector.modifierDown(at: 1.0)
        XCTAssertTrue(detector.modifierUp(at: 1.1), "第二次轻点")
    }

    func testIsolatedTapContaminationClearsAfterUp() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        detector.otherKeyDown()
        XCTAssertFalse(detector.modifierUp(at: 0.1), "夹键的这次不触发")
        // 污染随松开复位：下一次干净轻点应触发。
        detector.modifierDown(at: 1.0)
        XCTAssertTrue(detector.modifierUp(at: 1.05))
    }

    func testIsolatedTapDownIsIdempotentKeepsFirstTimestamp() {
        var detector = IsolatedTapDetector(window: 0.3)
        detector.modifierDown(at: 0.0)
        // 重复按下边沿不应刷新起点（保险防自动重复）。
        detector.modifierDown(at: 0.25)
        // 以首次 0.0 计：到 0.4 已超窗口 -> 不触发。
        XCTAssertFalse(detector.modifierUp(at: 0.4))
    }

    // MARK: - SingleTapToggleStateMachine（孤立轻点 -> start，再次 -> stop）

    func testSingleTapToggleAlternatesStartStop() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.modifierDown(at: 0.0)
        XCTAssertEqual(machine.modifierUp(at: 0.1), .start, "首个孤立轻点开始")
        machine.modifierDown(at: 1.0)
        XCTAssertEqual(machine.modifierUp(at: 1.1), .stop, "再次轻点结束")
        machine.modifierDown(at: 2.0)
        XCTAssertEqual(machine.modifierUp(at: 2.1), .start, "第三次轻点重新开始")
    }

    func testSingleTapToggleChordDoesNotToggle() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.modifierDown(at: 0.0)
        machine.otherKeyDown()
        // 夹了普通键（快捷键）-> 不触发、会话状态不变。
        XCTAssertNil(machine.modifierUp(at: 0.1))
        // 之后一次干净轻点应正常 start（证明会话仍处于未激活）。
        machine.modifierDown(at: 1.0)
        XCTAssertEqual(machine.modifierUp(at: 1.1), .start)
    }

    func testSingleTapToggleLongPressDoesNotToggle() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.modifierDown(at: 0.0)
        // 长按超窗口不触发。
        XCTAssertNil(machine.modifierUp(at: 0.6))
    }

    func testSingleTapToggleResetDoesNotChangeActiveState() {
        var machine = SingleTapToggleStateMachine(window: 0.3)
        machine.modifierDown(at: 0.0)
        XCTAssertEqual(machine.modifierUp(at: 0.1), .start)
        // reset 仅作废进行中的候选轻点，不改变「已激活」会话。
        machine.modifierDown(at: 1.0)
        machine.reset()
        // reset 后松开不触发（候选已作废）。
        XCTAssertNil(machine.modifierUp(at: 1.05))
        // 下一次干净轻点应给 .stop（会话仍是激活态）。
        machine.modifierDown(at: 2.0)
        XCTAssertEqual(machine.modifierUp(at: 2.1), .stop)
    }
}
