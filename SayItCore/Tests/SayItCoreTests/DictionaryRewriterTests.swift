import XCTest
@testable import SayItCore

/// Pure-function unit tests for DictionaryMatcher + DictionaryRewriter (Layer 3).
///
/// The matcher is a pure function, tested mainly via the ``DictionaryRewriter/apply(to:using:)`` facade;
/// coverage: useEffect all-variant normalization, multi-token merge, canonical case preservation, whole-word safety,
/// caseSensitive, enabled==false, and the identity (zero behavior change) of an empty dictionary / irrelevant entries.
final class DictionaryRewriterTests: XCTestCase {

    /// The standard useEffect entry: canonical form + three heard/misheard forms.
    private func useEffectEntry(caseSensitive: Bool = false, enabled: Bool = true) -> DictionaryEntry {
        DictionaryEntry(
            canonical: "useEffect",
            variants: ["use effect", "use-effect", "UseEffect"],
            caseSensitive: caseSensitive,
            enabled: enabled
        )
    }

    // MARK: - useEffect all-variant normalization

    func testUseEffectCanonicalStaysCanonical() {
        let out = DictionaryRewriter.apply(to: "Call useEffect here", using: [useEffectEntry()])
        XCTAssertEqual(out, "Call useEffect here")
    }

    func testUseEffectPascalCaseRewritten() {
        let out = DictionaryRewriter.apply(to: "Call UseEffect here", using: [useEffectEntry()])
        XCTAssertEqual(out, "Call useEffect here")
    }

    func testUseEffectSpacedRewritten() {
        let out = DictionaryRewriter.apply(to: "Call use effect here", using: [useEffectEntry()])
        XCTAssertEqual(out, "Call useEffect here")
    }

    func testUseEffectHyphenatedRewritten() {
        let out = DictionaryRewriter.apply(to: "Call use-effect here", using: [useEffectEntry()])
        XCTAssertEqual(out, "Call useEffect here")
    }

    func testUseEffectLowercasedRunOnRewritten() {
        // The all-lowercase "useeffect" hits the canonical key case-insensitively -> normalized to the stored useEffect.
        let out = DictionaryRewriter.apply(to: "the useeffect hook", using: [useEffectEntry()])
        XCTAssertEqual(out, "the useEffect hook")
    }

    // MARK: - Multi-token merge

    func testMultiTokenMergeCollapsesSpacedSpan() {
        let out = DictionaryRewriter.apply(to: "use effect", using: [useEffectEntry()])
        XCTAssertEqual(out, "useEffect", "two tokens across whitespace should merge into the canonical form")
    }

    func testMultiTokenMergePreservesSurroundingPunctuation() {
        let out = DictionaryRewriter.apply(to: "(use effect),", using: [useEffectEntry()])
        XCTAssertEqual(out, "(useEffect),", "surrounding punctuation is preserved byte-for-byte after merging")
    }

    func testMultiTokenMergeDoesNotCrossNonMergeableSeparator() {
        // A period separator does not form a mergeable spoken segment: should not merge.
        let out = DictionaryRewriter.apply(to: "use. effect", using: [useEffectEntry()])
        XCTAssertEqual(out, "use. effect")
    }

    // MARK: - Canonical case preservation (case-insensitive hit -> output the stored form)

    func testCanonicalCasePreservedOnCaseInsensitiveHit() {
        let entry = DictionaryEntry(canonical: "GitHub", variants: ["github", "git hub"])
        XCTAssertEqual(DictionaryRewriter.apply(to: "on github today", using: [entry]), "on GitHub today")
        XCTAssertEqual(DictionaryRewriter.apply(to: "on GITHUB today", using: [entry]), "on GitHub today")
        XCTAssertEqual(DictionaryRewriter.apply(to: "on git hub today", using: [entry]), "on GitHub today")
    }

    // MARK: - Whole-word boundary safety

    func testWholeWordSafetyDoesNotTouchSubstring() {
        // Cat -> Dog must never turn Caterpillar into Dogerpillar.
        let entry = DictionaryEntry(canonical: "Dog", variants: ["Cat"])
        let out = DictionaryRewriter.apply(to: "The Caterpillar saw a Cat.", using: [entry])
        XCTAssertEqual(out, "The Caterpillar saw a Dog.")
    }

    func testWholeWordSafetyAtStringBoundaries() {
        let entry = DictionaryEntry(canonical: "Dog", variants: ["Cat"])
        XCTAssertEqual(DictionaryRewriter.apply(to: "Cat", using: [entry]), "Dog")
        XCTAssertEqual(DictionaryRewriter.apply(to: "Cats", using: [entry]), "Cats", "Cats is not the whole word Cat")
        XCTAssertEqual(DictionaryRewriter.apply(to: "scat", using: [entry]), "scat", "scat does not contain the whole word Cat")
    }

    // MARK: - caseSensitive: only normalizes the exact-case form

    func testCaseSensitiveOnlyRewritesExactCase() {
        // Case-sensitive entry: only preserves/normalizes the form that is exactly "GPT", does not touch "gpt".
        let entry = DictionaryEntry(canonical: "GPT", variants: ["GPT"], caseSensitive: true)
        XCTAssertEqual(DictionaryRewriter.apply(to: "use GPT now", using: [entry]), "use GPT now")
        XCTAssertEqual(DictionaryRewriter.apply(to: "use gpt now", using: [entry]), "use gpt now",
                       "with case sensitivity, lowercase gpt should not be changed")
    }

    func testCaseSensitiveVariantRewritesToCanonical() {
        // Case-sensitive: an exact-case variant match -> normalized to canonical.
        let entry = DictionaryEntry(canonical: "iOS", variants: ["IOS"], caseSensitive: true)
        XCTAssertEqual(DictionaryRewriter.apply(to: "the IOS app", using: [entry]), "the iOS app")
        XCTAssertEqual(DictionaryRewriter.apply(to: "the ios app", using: [entry]), "the ios app",
                       "with case sensitivity, ios does not match IOS")
    }

    // MARK: - enabled==false never rewrites

    func testDisabledEntryNeverRewrites() {
        let out = DictionaryRewriter.apply(to: "Call use effect here", using: [useEffectEntry(enabled: false)])
        XCTAssertEqual(out, "Call use effect here", "a disabled entry should not participate in rewriting")
    }

    // MARK: - Empty dictionary / irrelevant entries: identity (zero behavior change)

    func testEmptyDictionaryIsIdentity() {
        XCTAssertEqual(DictionaryRewriter.apply(to: "x", using: []), "x")
        XCTAssertEqual(DictionaryRewriter.apply(to: "anything at all here", using: []),
                       "anything at all here")
    }

    func testIrrelevantEntriesLeaveTextUnchanged() {
        let entry = useEffectEntry()
        let text = "totally unrelated sentence with no terms"
        XCTAssertEqual(DictionaryRewriter.apply(to: text, using: [entry]), text)
    }

    func testEmptyTextIsIdentity() {
        XCTAssertEqual(DictionaryRewriter.apply(to: "", using: [useEffectEntry()]), "")
    }

    func testEntryWithAllEmptyFormsIsIgnored() {
        // Whitespace canonical + no valid variant: should be dropped during rule building, text is identity.
        let entry = DictionaryEntry(canonical: "   ", variants: ["  "])
        XCTAssertEqual(DictionaryRewriter.apply(to: "hello world", using: [entry]), "hello world")
    }

    // MARK: - Combined: multiple hits + surrounding text preserved byte-for-byte

    func testMultipleHitsInOneSentencePreserveEverythingElse() {
        let entry = useEffectEntry()
        let out = DictionaryRewriter.apply(
            to: "First use effect, then UseEffect, finally useEffect.",
            using: [entry])
        XCTAssertEqual(out, "First useEffect, then useEffect, finally useEffect.")
    }

    func testDeterministicAcrossRepeatedCalls() {
        let entry = useEffectEntry()
        let input = "wrap use-effect and use effect together"
        let first = DictionaryRewriter.apply(to: input, using: [entry])
        let second = DictionaryRewriter.apply(to: input, using: [entry])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "wrap useEffect and useEffect together")
    }
}
