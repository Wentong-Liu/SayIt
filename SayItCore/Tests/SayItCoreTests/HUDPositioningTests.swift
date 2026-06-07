import XCTest
import CoreGraphics
@testable import SayItCore

final class HUDPositioningTests: XCTestCase {
    private let size = CGSize(width: 160, height: 56)
    // The main screen's visible region (bottom-left origin; simulating the region after removing the menu bar).
    private let vf = CGRect(x: 0, y: 0, width: 1440, height: 860)

    func testBottomCenterIsHorizontallyCentered() {
        let origin = HUDPositioning.bottomCenterOrigin(size: size, within: vf, bottomMargin: 80)
        XCTAssertEqual(origin.x, (vf.width - size.width) / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, vf.minY + 80, accuracy: 0.001)
    }

    func testBottomCenterRespectsVisibleFrameOffset() {
        // Secondary screen: the visible region origin has an x/y offset, the anchor must be centered relative to that screen.
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
        // The anchor pushes the panel out of the top-right corner; after clamping it must stick to the right/top boundary.
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
        // The HUD is larger than the visible region: the lower bound takes priority, at least the bottom-left corner aligns with the visible region's bottom-left.
        let tiny = CGRect(x: 10, y: 10, width: 100, height: 30)
        let clamped = HUDPositioning.clamped(origin: CGPoint(x: 500, y: 500), size: size, within: tiny)
        XCTAssertEqual(clamped.x, tiny.minX, accuracy: 0.001)
        XCTAssertEqual(clamped.y, tiny.minY, accuracy: 0.001)
    }
}

final class RecordingStateTests: XCTestCase {
    /// Fixed-state copy has been localized since T24 (en + zh-Hans), so it asserts "belongs to that language's set" per the supported language,
    /// no longer hardcoding a single Chinese string, to avoid false reds as the test process locale drifts. Also ensures it is not an untranslated key name.
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

    /// The specific copy passed in by the caller is preserved as-is (independent of locale).
    func testDisplayTextPassesThroughProvidedMessage() {
        XCTAssertEqual(RecordingState.error("网络异常").displayText, "网络异常")
        XCTAssertEqual(RecordingState.info("已粘贴到当前窗口").displayText, "已粘贴到当前窗口")
    }

    /// The "local model not ready" hint is localized (en + zh-Hans), asserted per the supported language set, and must not fall back to the original key.
    func testModelNotReadyMessageLocalizedToSupportedLanguage() {
        let supported = [
            "Local model still downloading — please wait or switch to cloud",
            "本地模型仍在下载，请稍候或切换到云端",
        ]
        let message = RecordingState.modelNotReadyMessage
        XCTAssertNotEqual(message, "hud.modelNotReady", "不应回退成原始 key：本地化资源未命中")
        XCTAssertTrue(supported.contains(message), "got \(message)")
    }

    /// The "taking longer than usual" hint is localized (en + zh-Hans), asserted per the supported language set, and must not fall back to the original key.
    func testTakingLongerMessageLocalizedToSupportedLanguage() {
        let supported = [
            "Taking longer than usual…",
            "转写时间比往常要长",
        ]
        let message = RecordingState.takingLongerMessage
        XCTAssertNotEqual(message, "hud.takingLonger", "不应回退成原始 key：本地化资源未命中")
        XCTAssertTrue(supported.contains(message), "got \(message)")
    }

    func testErrorTextTrimsAndFallsBack() {
        XCTAssertEqual(RecordingState.error("  超时  ").displayText, "超时")
        // An empty message falls back to the localized generic error copy (one of en or zh-Hans).
        let errorFallbacks = ["Something went wrong", "出错了"]
        XCTAssertTrue(errorFallbacks.contains(RecordingState.error("   ").displayText))
        XCTAssertTrue(errorFallbacks.contains(RecordingState.error("").displayText))
    }

    func testInfoTextTrimsAndFallsBack() {
        XCTAssertEqual(RecordingState.info("  已粘贴  ").displayText, "已粘贴")
        let doneFallbacks = ["Done", "完成"]
        XCTAssertTrue(doneFallbacks.contains(RecordingState.info("   ").displayText))
    }

    /// The processing-state "transcribing vs polish" distinction is carried entirely by the copy (decoupled from the progress-bar position):
    /// at the same progress value, switching only the phase should yield different copy (Transcribing… / Polishing…), proving the phase drives the text only.
    func testProcessingPhaseDrivesLabelNotBarValue() {
        let transcribing = ["Transcribing…", "识别中…"]
        let polishing = ["Polishing…", "润色中…"]

        // At the same progress (0.0), differing only in phase produces different copy.
        let t0 = RecordingState.processing(progress: 0.0, phase: .transcribing).displayText
        let p0 = RecordingState.processing(progress: 0.0, phase: .polishing).displayText
        // The polish copy resolves through the in-bundle catalog (hud.polishing), not a raw key fallback.
        XCTAssertNotEqual(p0, "hud.polishing", "不应回退成原始 key：本地化资源未命中")
        XCTAssertTrue(transcribing.contains(t0), "got \(t0)")
        XCTAssertTrue(polishing.contains(p0), "got \(p0)")
        XCTAssertNotEqual(t0, p0, "switching the phase must change the copy")

        // The copy only looks at the phase, not the progress: different progress but the same phase keeps the copy consistent.
        let p05 = RecordingState.processing(progress: 0.5, phase: .polishing).displayText
        let p09 = RecordingState.processing(progress: 0.9, phase: .polishing).displayText
        XCTAssertEqual(p0, p05)
        XCTAssertEqual(p05, p09)
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
