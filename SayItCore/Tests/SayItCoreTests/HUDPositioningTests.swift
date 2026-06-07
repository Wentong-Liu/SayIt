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
    /// 固定态文案自 T24 起本地化（en + zh-Hans），故按受支持语言断言「属于该语言集」，
    /// 不再硬编码单一中文，以免随测试进程 locale 漂移而误红。同时确保不是未翻译的键名。
    func testDisplayTextLocalizedToSupportedLanguage() {
        let listening = ["Listening…", "聆听中…"]
        let transcribing = ["Transcribing…", "识别中…"]
        let idle = ["Ready", "准备就绪"]

        XCTAssertTrue(listening.contains(RecordingState.listening.displayText),
                      "got \(RecordingState.listening.displayText)")
        XCTAssertTrue(transcribing.contains(RecordingState.transcribing.displayText),
                      "got \(RecordingState.transcribing.displayText)")
        XCTAssertTrue(idle.contains(RecordingState.idle.displayText),
                      "got \(RecordingState.idle.displayText)")
    }

    /// 调用方传入的具体文案原样保留（与 locale 无关）。
    func testDisplayTextPassesThroughProvidedMessage() {
        XCTAssertEqual(RecordingState.error("网络异常").displayText, "网络异常")
        XCTAssertEqual(RecordingState.info("已粘贴到当前窗口").displayText, "已粘贴到当前窗口")
    }

    /// 「本地模型未就绪」提示已本地化（en + zh-Hans），按受支持语言集断言，且不得回退成原始 key。
    func testModelNotReadyMessageLocalizedToSupportedLanguage() {
        let supported = [
            "Local model still downloading — please wait or switch to cloud",
            "本地模型仍在下载，请稍候或切换到云端",
        ]
        let message = RecordingState.modelNotReadyMessage
        XCTAssertNotEqual(message, "hud.modelNotReady", "不应回退成原始 key：本地化资源未命中")
        XCTAssertTrue(supported.contains(message), "got \(message)")
    }

    func testErrorTextTrimsAndFallsBack() {
        XCTAssertEqual(RecordingState.error("  超时  ").displayText, "超时")
        // 空消息回落到本地化通用错误文案（en 或 zh-Hans 之一）。
        let errorFallbacks = ["Something went wrong", "出错了"]
        XCTAssertTrue(errorFallbacks.contains(RecordingState.error("   ").displayText))
        XCTAssertTrue(errorFallbacks.contains(RecordingState.error("").displayText))
    }

    func testInfoTextTrimsAndFallsBack() {
        XCTAssertEqual(RecordingState.info("  已粘贴  ").displayText, "已粘贴")
        let doneFallbacks = ["Done", "完成"]
        XCTAssertTrue(doneFallbacks.contains(RecordingState.info("   ").displayText))
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
