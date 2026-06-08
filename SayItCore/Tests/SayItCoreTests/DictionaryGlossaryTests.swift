import XCTest
@testable import SayItCore

/// Unit tests for ``DictionaryGlossary`` — the Layer 2 candidate selection helper.
final class DictionaryGlossaryTests: XCTestCase {

    private func entry(_ canonical: String,
                       variants: [String] = [],
                       enabled: Bool = true,
                       usageCount: Int = 0,
                       createdAt: Date = Date(timeIntervalSince1970: 0)) -> DictionaryEntry {
        DictionaryEntry(canonical: canonical,
                        variants: variants,
                        enabled: enabled,
                        createdAt: createdAt,
                        usageCount: usageCount)
    }

    private func canonicals(_ entries: [DictionaryEntry]) -> [String] {
        entries.map(\.canonical)
    }

    // MARK: - Small dictionary includes all

    func testSmallDictionaryIncludesAllEnabledEntries() {
        // When the dictionary is small (<= cap), include all enabled entries without lexical filtering.
        let entries = [entry("useEffect"), entry("kubectl"), entry("SwiftUI")]
        let subset = DictionaryGlossary.relevantSubset(for: "完全无关的中文转写", entries: entries)
        XCTAssertEqual(Set(canonicals(subset)), Set(["useEffect", "kubectl", "SwiftUI"]),
                       "a small dictionary should include all entries even when the transcript contains no dictionary terms")
    }

    // MARK: - Disabled entries excluded

    func testDisabledEntriesAreExcluded() {
        let entries = [entry("useEffect"), entry("kubectl", enabled: false)]
        let subset = DictionaryGlossary.relevantSubset(for: "随便", entries: entries)
        XCTAssertEqual(canonicals(subset), ["useEffect"], "disabled entries should not be included")
    }

    func testBlankCanonicalExcluded() {
        let entries = [entry("useEffect"), entry("   ")]
        let subset = DictionaryGlossary.relevantSubset(for: "随便", entries: entries)
        XCTAssertEqual(canonicals(subset), ["useEffect"], "a blank canonical should not be included")
    }

    func testEmptyDictionaryReturnsEmpty() {
        XCTAssertTrue(DictionaryGlossary.relevantSubset(for: "随便", entries: []).isEmpty,
                      "an empty dictionary should return an empty subset")
    }

    // MARK: - Candidate matching (large dictionary path)

    /// Builds a dictionary larger than `cap` so the lexical filter actually runs.
    private func largeDictionary(including extra: [DictionaryEntry], cap: Int) -> [DictionaryEntry] {
        // Filler entries with canonicals that will never appear in the test transcripts.
        let filler = (0..<(cap + 5)).map { entry("zzzfiller\($0)") }
        return extra + filler
    }

    func testCamelCaseTermMatchedFromSpokenForm() {
        let cap = 3
        let dict = largeDictionary(including: [entry("useEffect")], cap: cap)
        // "use effect" is the de-camelCased spoken form of useEffect.
        let subset = DictionaryGlossary.relevantSubset(for: "我们要在这里加一个 use effect 钩子", entries: dict, cap: cap)
        XCTAssertTrue(canonicals(subset).contains("useEffect"),
                      "should match useEffect when heard as 'use effect'")
    }

    func testCamelCaseTermMatchedFromDifferentCasing() {
        let cap = 3
        let dict = largeDictionary(including: [entry("useEffect")], cap: cap)
        let subset = DictionaryGlossary.relevantSubset(for: "调用 UseEffect 试试", entries: dict, cap: cap)
        XCTAssertTrue(canonicals(subset).contains("useEffect"),
                      "should match useEffect for a different casing 'UseEffect'")
    }

    func testHyphenAndUnderscoreVariantsMatched() {
        let cap = 3
        let dict = largeDictionary(including: [entry("useEffect")], cap: cap)
        let viaHyphen = DictionaryGlossary.relevantSubset(for: "用 use-effect 处理", entries: dict, cap: cap)
        XCTAssertTrue(canonicals(viaHyphen).contains("useEffect"), "the hyphenated variant should match (splitSeparators)")
    }

    func testUnrelatedTranscriptSelectsNothingFromLargeDictionary() {
        let cap = 3
        let dict = largeDictionary(including: [entry("useEffect"), entry("kubectl")], cap: cap)
        let subset = DictionaryGlossary.relevantSubset(for: "今天天气真不错我们去公园散步", entries: dict, cap: cap)
        XCTAssertTrue(subset.isEmpty, "should return empty when the large dictionary has no relevant term")
    }

    func testDeclaredVariantMatched() {
        let cap = 3
        let dict = largeDictionary(including: [entry("kubectl", variants: ["cube cuddle"])], cap: cap)
        let subset = DictionaryGlossary.relevantSubset(for: "我跑了 cube cuddle 命令", entries: dict, cap: cap)
        XCTAssertTrue(canonicals(subset).contains("kubectl"), "a declared variant should match")
    }

    // MARK: - Short-form noise suppression

    func testVeryShortFormRequiresTokenMatchNotSubstring() {
        let cap = 3
        let dict = largeDictionary(including: [entry("go")], cap: cap)
        // "good" contains "go" as a substring but not as a token -> must NOT match.
        let noMatch = DictionaryGlossary.relevantSubset(for: "this looks good to me", entries: dict, cap: cap)
        XCTAssertFalse(canonicals(noMatch).contains("go"),
                       "a term of <=2 chars must match as a whole token; the 'go' inside substring 'good' must not match")
        // Standalone "go" token -> matches.
        let match = DictionaryGlossary.relevantSubset(for: "let us go now", entries: dict, cap: cap)
        XCTAssertTrue(canonicals(match).contains("go"), "a standalone token 'go' should match")
    }

    // MARK: - Cap respected + ordering

    func testCapRespectedForLargeDictionary() {
        let cap = 2
        // 4 matching entries, all present in the transcript -> capped to 2.
        let matching = [
            entry("alpha", usageCount: 1),
            entry("beta", usageCount: 5),
            entry("gamma", usageCount: 3),
            entry("delta", usageCount: 10),
        ]
        let dict = largeDictionary(including: matching, cap: cap)
        let transcript = "alpha beta gamma delta all present"
        let subset = DictionaryGlossary.relevantSubset(for: transcript, entries: dict, cap: cap)
        XCTAssertEqual(subset.count, cap, "should be trimmed to the cap limit")
        // Highest usageCount preferred: delta(10) then beta(5).
        XCTAssertEqual(canonicals(subset), ["delta", "beta"],
                       "should prefer inclusion by descending usageCount")
    }

    func testDeterministicOrderingTieBreaksByCreatedAtThenCanonical() {
        let cap = 2
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let matching = [
            entry("alpha", usageCount: 5, createdAt: older),
            entry("beta", usageCount: 5, createdAt: newer),
        ]
        let dict = largeDictionary(including: matching, cap: cap)
        let subset = DictionaryGlossary.relevantSubset(for: "alpha beta", entries: dict, cap: cap)
        // Same usageCount -> most recent createdAt first (beta).
        XCTAssertEqual(canonicals(subset), ["beta", "alpha"],
                       "when usageCount is equal, order by createdAt descending (newest first)")
    }

    func testDedupeByCanonical() {
        let entries = [entry("useEffect"), entry("useEffect", variants: ["dup"])]
        let subset = DictionaryGlossary.relevantSubset(for: "随便", entries: entries)
        XCTAssertEqual(canonicals(subset), ["useEffect"], "should dedupe by canonical")
    }

    // MARK: - String helpers

    func testDeCamelCased() {
        XCTAssertEqual(DictionaryGlossary.deCamelCased("useEffect"), "use effect")
        XCTAssertEqual(DictionaryGlossary.deCamelCased("URLSession"), "url session")
        XCTAssertEqual(DictionaryGlossary.deCamelCased("SwiftUI"), "swift ui")
        XCTAssertEqual(DictionaryGlossary.deCamelCased("simple"), "simple")
    }

    func testSplitSeparators() {
        XCTAssertEqual(DictionaryGlossary.splitSeparators("use-effect"), "use effect")
        XCTAssertEqual(DictionaryGlossary.splitSeparators("use_effect"), "use effect")
    }
}
