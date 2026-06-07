import XCTest
@testable import SayItCore

/// HotkeyManager 壳层的可测面：配置默认值与启停生命周期（幂等性、isRunning 标志）。
/// 真实的全局事件注入不在单测范围内——其判定逻辑已由纯状态机测试覆盖。
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
        // 仅验证可被调用且返回布尔（CI 环境通常未授权 -> false）。
        let manager = HotkeyManager()
        _ = manager.isProcessTrusted
        _ = HotkeyManager.isProcessTrusted
    }
}
