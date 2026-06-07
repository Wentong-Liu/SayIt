import XCTest
import CoreGraphics
@testable import SayItCore

final class HUDPositioningTests: XCTestCase {
    private let size = CGSize(width: 160, height: 56)
    // 主屏可见区（左下原点；模拟去掉菜单栏后的区域）。
    private let vf = CGRect(x: 0, y: 0, width: 1440, height: 860)

    func testBottomCenterIsHorizontallyCentered() {
        let origin = HUDPositioning.bottomCenterOrigin(size: size, within: vf, bottomMargin: 80)
        XCTAssertEqual(origin.x, (vf.width - size.width) / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, vf.minY + 80, accuracy: 0.001)
    }

    func testBottomCenterRespectsVisibleFrameOffset() {
        // 副屏：可见区原点带 x/y 偏移，锚点须相对该屏居中。
        let off = CGRect(x: 1440, y: 200, width: 1000, height: 600)
        let origin = HUDPositioning.bottomCenterOrigin(size: size, within: off, bottomMargin: 50)
        XCTAssertEqual(origin.x, off.minX + (off.width - size.width) / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, off.minY + 50, accuracy: 0.001)
    }

    func testAboveCursorCentersHorizontallyAndSitsAbove() {
        let cursor = CGPoint(x: 700, y: 400)
        let origin = HUDPositioning.aboveCursorOrigin(cursor: cursor, size: size, gap: 24)
        XCTAssertEqual(origin.x, cursor.x - size.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, cursor.y + 24, accuracy: 0.001)
    }

    func testClampKeepsInsideVisibleFrameWhenInBounds() {
        let inside = CGPoint(x: 100, y: 100)
        let clamped = HUDPositioning.clamped(origin: inside, size: size, within: vf)
        XCTAssertEqual(clamped, inside)
    }

    func testClampPullsBackFromRightAndTopOverflow() {
        // 锚点把面板推出右上角，夹紧后须贴住右/上边界。
        let overflowing = CGPoint(x: vf.maxX + 50, y: vf.maxY + 50)
        let clamped = HUDPositioning.clamped(origin: overflowing, size: size, within: vf)
        XCTAssertEqual(clamped.x, vf.maxX - size.width, accuracy: 0.001)
        XCTAssertEqual(clamped.y, vf.maxY - size.height, accuracy: 0.001)
    }

    func testClampPullsBackFromLeftAndBottomOverflow() {
        let overflowing = CGPoint(x: -100, y: -100)
        let clamped = HUDPositioning.clamped(origin: overflowing, size: size, within: vf)
        XCTAssertEqual(clamped.x, vf.minX, accuracy: 0.001)
        XCTAssertEqual(clamped.y, vf.minY, accuracy: 0.001)
    }

    func testClampWithOversizedHUDFallsBackToLowerBound() {
        // HUD 比可见区还大：下界优先，至少左下角对齐可见区左下角。
        let tiny = CGRect(x: 10, y: 10, width: 100, height: 30)
        let clamped = HUDPositioning.clamped(origin: CGPoint(x: 500, y: 500), size: size, within: tiny)
        XCTAssertEqual(clamped.x, tiny.minX, accuracy: 0.001)
        XCTAssertEqual(clamped.y, tiny.minY, accuracy: 0.001)
    }
}

final class RecordingStateTests: XCTestCase {
    func testDisplayText() {
        XCTAssertEqual(RecordingState.listening.displayText, "聆听中…")
        XCTAssertEqual(RecordingState.transcribing.displayText, "识别中…")
        XCTAssertEqual(RecordingState.error("网络异常").displayText, "网络异常")
        XCTAssertEqual(RecordingState.info("已粘贴到当前窗口").displayText, "已粘贴到当前窗口")
        XCTAssertEqual(RecordingState.idle.displayText, "准备就绪")
    }

    func testErrorTextTrimsAndFallsBack() {
        XCTAssertEqual(RecordingState.error("  超时  ").displayText, "超时")
        XCTAssertEqual(RecordingState.error("   ").displayText, "出错了")
        XCTAssertEqual(RecordingState.error("").displayText, "出错了")
    }

    func testInfoTextTrimsAndFallsBack() {
        XCTAssertEqual(RecordingState.info("  已粘贴  ").displayText, "已粘贴")
        XCTAssertEqual(RecordingState.info("   ").displayText, "完成")
    }

    func testVisibility() {
        XCTAssertFalse(RecordingState.idle.isVisible)
        XCTAssertTrue(RecordingState.listening.isVisible)
        XCTAssertTrue(RecordingState.transcribing.isVisible)
        XCTAssertTrue(RecordingState.info("x").isVisible)
        XCTAssertTrue(RecordingState.error("x").isVisible)
    }

    func testEquatable() {
        XCTAssertEqual(RecordingState.error("a"), RecordingState.error("a"))
        XCTAssertNotEqual(RecordingState.error("a"), RecordingState.error("b"))
        XCTAssertNotEqual(RecordingState.listening, RecordingState.transcribing)
    }
}
