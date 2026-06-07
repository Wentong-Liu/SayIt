import XCTest
@testable import SayItCore

/// Unit test for the shared, pure ``GlossaryPrompt`` builder used by both transcribers (Layer 1 STT biasing).
final class GlossaryPromptTests: XCTestCase {

    func testEmptyInputYieldsEmptyString() {
        XCTAssertEqual(GlossaryPrompt.compactList(from: [GlossaryPrompt.Term]()), "")
    }

    func testJoinsWithCommaSpace() {
        let terms = [GlossaryPrompt.Term(canonical: "alpha"), GlossaryPrompt.Term(canonical: "beta")]
        XCTAssertEqual(GlossaryPrompt.compactList(from: terms), "alpha, beta")
    }

    func testTrimsAndDropsBlanks() {
        let terms = [
            GlossaryPrompt.Term(canonical: "  alpha  "),
            GlossaryPrompt.Term(canonical: "   "),
            GlossaryPrompt.Term(canonical: ""),
            GlossaryPrompt.Term(canonical: "beta"),
        ]
        XCTAssertEqual(GlossaryPrompt.compactList(from: terms), "alpha, beta")
    }

    func testDedupesCaseInsensitively() {
        let terms = [
            GlossaryPrompt.Term(canonical: "SwiftUI"),
            GlossaryPrompt.Term(canonical: "swiftui"),
            GlossaryPrompt.Term(canonical: "Combine"),
        ]
        // First-seen surface form wins; the case-insensitive duplicate is dropped.
        XCTAssertEqual(GlossaryPrompt.compactList(from: terms), "SwiftUI, Combine")
    }

    func testOrdersByUsageCountAscendingMostUsedLast() {
        // Highest usageCount must sit LAST (nearest the decode start where prompt conditioning is strongest).
        let terms = [
            GlossaryPrompt.Term(canonical: "rare", usageCount: 1),
            GlossaryPrompt.Term(canonical: "common", usageCount: 99),
            GlossaryPrompt.Term(canonical: "mid", usageCount: 50),
        ]
        XCTAssertEqual(GlossaryPrompt.compactList(from: terms), "rare, mid, common")
    }

    func testEqualUsageKeepsInputOrder() {
        let terms = [
            GlossaryPrompt.Term(canonical: "first", usageCount: 0),
            GlossaryPrompt.Term(canonical: "second", usageCount: 0),
            GlossaryPrompt.Term(canonical: "third", usageCount: 0),
        ]
        XCTAssertEqual(GlossaryPrompt.compactList(from: terms), "first, second, third")
    }

    func testEntriesOverloadUsesCanonicalAndUsage() {
        let entries = [
            DictionaryEntry(canonical: "rare", usageCount: 1),
            DictionaryEntry(canonical: "common", usageCount: 10),
        ]
        XCTAssertEqual(GlossaryPrompt.compactList(from: entries), "rare, common")
    }
}
