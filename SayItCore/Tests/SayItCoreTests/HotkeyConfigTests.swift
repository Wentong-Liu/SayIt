import XCTest
import AppKit
@testable import SayItCore

/// TriggerKey 与 HotkeyMode 的配置层单测（不触碰系统事件监听）。
final class HotkeyConfigTests: XCTestCase {

    func testDefaultTriggerKeyIsRightCommand() {
        XCTAssertEqual(TriggerKey.default, .rightCommand)
    }

    func testTriggerKeyKeyCodesAreDistinct() {
        let codes = TriggerKey.allCases.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count, "每个触发键的 keyCode 必须唯一")
    }

    func testModifierTriggerKeysExposeModifierFlag() {
        XCTAssertEqual(TriggerKey.rightCommand.modifierFlag, .command)
        XCTAssertEqual(TriggerKey.leftCommand.modifierFlag, .command)
        XCTAssertEqual(TriggerKey.rightOption.modifierFlag, .option)
        XCTAssertEqual(TriggerKey.rightControl.modifierFlag, .control)
    }

    func testFnGlobeIsReservedWithFunctionFlag() {
        // Fn/Globe 预留：modifierFlag 用 .function。
        XCTAssertTrue(TriggerKey.allCases.contains(.fnGlobe))
        XCTAssertEqual(TriggerKey.fnGlobe.modifierFlag, .function)
    }

    func testEveryTriggerKeyHasNonEmptyLabel() {
        for key in TriggerKey.allCases {
            XCTAssertFalse(key.label.isEmpty, "\(key) 缺少 label")
        }
    }

    func testTriggerKeyIsRawRepresentableRoundTrip() {
        for key in TriggerKey.allCases {
            XCTAssertEqual(TriggerKey(rawValue: key.rawValue), key)
        }
    }

    func testHotkeyModeHasHoldAndToggle() {
        XCTAssertTrue(HotkeyMode.allCases.contains(.holdToTalk))
        XCTAssertTrue(HotkeyMode.allCases.contains(.toggle))
    }
}
