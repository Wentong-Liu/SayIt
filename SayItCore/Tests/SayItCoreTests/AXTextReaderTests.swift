import XCTest
import AppKit
@testable import SayItCore

// MARK: - Test stub

/// A stub focused-text reader so callers can be tested without a live UI / focused field.
/// Mirrors `StubAXInserter` on the injection side.
@MainActor
final class StubFocusedTextReader: FocusedTextReading {
    var trusted: Bool
    var result: FocusedText?
    private(set) var readCount = 0
    init(trusted: Bool, result: FocusedText?) {
        self.trusted = trusted
        self.result = result
    }
    var isTrusted: Bool { trusted }
    func readFocusedText() -> FocusedText? {
        readCount += 1
        return result
    }
}

// MARK: - FocusedText value-type tests

@MainActor
final class FocusedTextTests: XCTestCase {
    func testFieldMapping() {
        let ft = FocusedText(value: "hello", selectedLocation: 2, selectedLength: 3)
        XCTAssertEqual(ft.value, "hello")
        XCTAssertEqual(ft.selectedLocation, 2)
        XCTAssertEqual(ft.selectedLength, 3)
    }

    func testEquality() {
        let a = FocusedText(value: "x", selectedLocation: 0, selectedLength: 0)
        let b = FocusedText(value: "x", selectedLocation: 0, selectedLength: 0)
        let c = FocusedText(value: "x", selectedLocation: nil, selectedLength: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testNilSelectionIsRepresentable() {
        let ft = FocusedText(value: "no selection", selectedLocation: nil, selectedLength: nil)
        XCTAssertNil(ft.selectedLocation)
        XCTAssertNil(ft.selectedLength)
    }
}

// MARK: - Protocol contract tests (via stub)

@MainActor
final class FocusedTextReadingContractTests: XCTestCase {
    func testStubReturnsNilWhenUnreadable() {
        let reader = StubFocusedTextReader(trusted: true, result: nil)
        XCTAssertNil(reader.readFocusedText())
        XCTAssertEqual(reader.readCount, 1)
    }

    func testStubReturnsValueWhenReadable() {
        let expected = FocusedText(value: "I met jon today", selectedLocation: 15, selectedLength: 0)
        let reader = StubFocusedTextReader(trusted: true, result: expected)
        XCTAssertEqual(reader.readFocusedText(), expected)
    }

    func testStubExposesTrustFlag() {
        XCTAssertFalse(StubFocusedTextReader(trusted: false, result: nil).isTrusted)
        XCTAssertTrue(StubFocusedTextReader(trusted: true, result: nil).isTrusted)
    }
}

// MARK: - Concrete AXTextReader smoke test

@MainActor
final class AXTextReaderTests: XCTestCase {
    /// The concrete reader needs a live focused UI element + accessibility trust, neither of which exists in a headless
    /// test run, so under the test harness it must degrade gracefully to `nil` WITHOUT crashing. Full live behavior is
    /// exercised manually (there is no headless AX fixture). This guards the "never crash, return nil" robustness contract.
    func testReadFocusedTextDegradesToNilUnderTestHarness() {
        let reader = AXTextReader()
        // Either not trusted, no focused field, secure input, or unreadable element — all must yield nil, never a crash.
        XCTAssertNil(reader.readFocusedText())
    }

    func testIsTrustedDoesNotCrash() {
        // Just exercising the trust query path; the value depends on the host's accessibility grant.
        _ = AXTextReader().isTrusted
    }
}
