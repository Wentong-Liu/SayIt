import XCTest
import AppKit
@testable import SayItCore

/// Config-layer unit test for TriggerKey and HotkeyMode (does not touch system event monitoring).
final class HotkeyConfigTests: XCTestCase {

    func testDefaultTriggerKeyIsRightOption() {
        XCTAssertEqual(TriggerKey.default, .rightOption)
    }

    func testTriggerKeyKeyCodesAreDistinct() {
        let codes = TriggerKey.allCases.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count, "each trigger key's keyCode must be unique")
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
            XCTAssertFalse(key.label.isEmpty, "\(key) is missing a label")
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
        XCTAssertEqual(HotkeyMode.allCases.count, 2, "the double-tap toggle mode has been removed; only two remain")
    }

    func testInteractionModeDefaultIsSingleTap() {
        XCTAssertEqual(InteractionMode.default, .singleTap)
    }

    func testInteractionModeHasOnlySingleTapAndHold() {
        XCTAssertTrue(InteractionMode.allCases.contains(.singleTap))
        XCTAssertTrue(InteractionMode.allCases.contains(.hold))
        XCTAssertEqual(InteractionMode.allCases.count, 2, "double-tap toggle has been removed; only single-tap toggle and hold-to-talk remain")
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
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) is missing a displayName")
        }
    }
}
