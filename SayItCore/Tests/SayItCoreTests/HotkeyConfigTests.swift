import XCTest
import AppKit
@testable import SayItCore

/// Config-layer unit test for TriggerKey and HotkeyMode (does not touch system event monitoring).
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
        // Fn/Globe reserved: modifierFlag uses .function.
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

    func testHotkeyModeHasBothModes() {
        XCTAssertTrue(HotkeyMode.allCases.contains(.holdToTalk))
        XCTAssertTrue(HotkeyMode.allCases.contains(.singleTapToggle))
        XCTAssertEqual(HotkeyMode.allCases.count, 2, "双击 toggle 模式已移除，仅余两种")
    }

    func testInteractionModeDefaultIsSingleTap() {
        XCTAssertEqual(InteractionMode.default, .singleTap)
    }

    func testInteractionModeHasOnlySingleTapAndHold() {
        XCTAssertTrue(InteractionMode.allCases.contains(.singleTap))
        XCTAssertTrue(InteractionMode.allCases.contains(.hold))
        XCTAssertEqual(InteractionMode.allCases.count, 2, "双击切换已移除，仅余单击切换与按住说话")
    }

    func testInteractionModeRawValueRoundTrip() {
        for mode in InteractionMode.allCases {
            XCTAssertEqual(InteractionMode(rawValue: mode.rawValue), mode)
        }
    }

    func testInteractionModeLegacyDoubleTapFallsBackToSingleTap() {
        // The previously persisted "toggle" (double-tap toggle) has been removed and should safely fall back to the default (tap to toggle).
        XCTAssertEqual(InteractionMode(rawValue: "toggle"), .singleTap)
        XCTAssertEqual(InteractionMode(rawValue: "doubleTap"), .singleTap)
    }

    func testInteractionModeDisplayNamesNonEmpty() {
        for mode in InteractionMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) 缺少 displayName")
        }
    }
}
