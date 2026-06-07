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

    // MARK: - Auto-derivation from canonical (single-word model: NO user-supplied variants)

    func testAutoDerivedCamelCaseSpacedAndHyphenated() {
        // Only the canonical "useEffect" — no variants. The matcher derives "use effect" / "use-effect" / "useeffect".
        let entry = DictionaryEntry(canonical: "useEffect")
        XCTAssertEqual(entry.variants, [], "precondition: this entry supplies no variants")
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call use effect here", using: [entry]), "Call useEffect here")
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call use-effect here", using: [entry]), "Call useEffect here")
        XCTAssertEqual(DictionaryRewriter.apply(to: "the useeffect hook", using: [entry]), "the useEffect hook")
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call UseEffect here", using: [entry]), "Call useEffect here",
                       "case-insensitive: the PascalCase spelling normalizes to the canonical")
    }

    func testAutoDerivedPascalCaseBigQuery() {
        // BigQuery -> "big query" / "big-query" derived, no variants supplied.
        let entry = DictionaryEntry(canonical: "BigQuery")
        XCTAssertEqual(DictionaryRewriter.apply(to: "load it into big query now", using: [entry]),
                       "load it into BigQuery now")
        XCTAssertEqual(DictionaryRewriter.apply(to: "load it into big-query now", using: [entry]),
                       "load it into BigQuery now")
        XCTAssertEqual(DictionaryRewriter.apply(to: "load it into BigQuery now", using: [entry]),
                       "load it into BigQuery now", "the canonical itself stays canonical")
    }

    func testAutoDerivedAcronymWordBoundary() {
        // Upper-run -> word boundary: HTTPServer -> "http server".
        let entry = DictionaryEntry(canonical: "HTTPServer")
        XCTAssertEqual(DictionaryRewriter.apply(to: "start the http server please", using: [entry]),
                       "start the HTTPServer please")
        XCTAssertEqual(DictionaryRewriter.apply(to: "start the http-server please", using: [entry]),
                       "start the HTTPServer please")
    }

    func testAutoDerivedWholeWordSafetyOnDerivedForms() {
        // Derived "use effect" must remain whole-word: trailing letters keep it as a separate (unmatched) word.
        let entry = DictionaryEntry(canonical: "useEffect")
        XCTAssertEqual(DictionaryRewriter.apply(to: "use effecting code", using: [entry]), "use effecting code",
                       "use effecting is not the whole derived form")
        XCTAssertEqual(DictionaryRewriter.apply(to: "use effects today", using: [entry]), "use effects today",
                       "use effects is not the whole derived form")
        // The single word "use" alone must not be rewritten by a derived multi-token form.
        XCTAssertEqual(DictionaryRewriter.apply(to: "use it well", using: [entry]), "use it well")
    }

    func testNoAutoDerivationForPlainLowercaseTerm() {
        // codex: single all-lowercase token -> no derived forms; exact/case-insensitive only, no over-correction.
        let entry = DictionaryEntry(canonical: "codex")
        XCTAssertEqual(DictionaryRewriter.apply(to: "open codex now", using: [entry]), "open codex now",
                       "the canonical matches itself (identity)")
        XCTAssertEqual(DictionaryRewriter.apply(to: "open CODEX now", using: [entry]), "open codex now",
                       "case-insensitive normalizes to canonical")
        XCTAssertEqual(DictionaryRewriter.apply(to: "write code here", using: [entry]), "write code here",
                       "the unrelated word 'code' must not be touched (no fabricated variants)")
    }

    func testNoAutoDerivationForAllCapsTerm() {
        // GPT: single all-caps token -> no derived multi-word form; "g p t" must not become "GPT".
        let entry = DictionaryEntry(canonical: "GPT")
        XCTAssertEqual(DictionaryRewriter.apply(to: "use GPT now", using: [entry]), "use GPT now")
        XCTAssertEqual(DictionaryRewriter.apply(to: "use gpt now", using: [entry]), "use GPT now",
                       "case-insensitive normalizes to canonical")
        XCTAssertEqual(DictionaryRewriter.apply(to: "g p t spelled out", using: [entry]), "g p t spelled out",
                       "an all-caps acronym derives no spoken multi-word form")
    }

    func testNoAutoDerivationForChineseTerm() {
        // A CJK term has no case boundaries -> no derived forms; matches exactly, unrelated text untouched.
        let entry = DictionaryEntry(canonical: "拓荆科技")
        XCTAssertEqual(DictionaryRewriter.apply(to: "我在拓荆科技工作", using: [entry]), "我在拓荆科技工作")
        XCTAssertEqual(DictionaryRewriter.apply(to: "今天天气不错", using: [entry]), "今天天气不错",
                       "unrelated Chinese text is untouched (no fabricated variants)")
    }

    func testAutoDerivationDeterministic() {
        let entry = DictionaryEntry(canonical: "useEffect")
        let input = "wrap use-effect and use effect together"
        let first = DictionaryRewriter.apply(to: input, using: [entry])
        let second = DictionaryRewriter.apply(to: input, using: [entry])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "wrap useEffect and useEffect together")
    }

    func testDerivedSpokenFormsPureHelper() {
        // Direct coverage of the derivation helper's contract (over-correction guard + multi-segment forms).
        XCTAssertEqual(DictionaryMatcher.Rule.derivedSpokenForms(from: "useEffect"),
                       ["use effect", "use-effect", "useeffect"])
        XCTAssertEqual(DictionaryMatcher.Rule.derivedSpokenForms(from: "BigQuery"),
                       ["big query", "big-query", "bigquery"])
        XCTAssertEqual(DictionaryMatcher.Rule.derivedSpokenForms(from: "HTTPServer"),
                       ["http server", "http-server", "httpserver"])
        // A typed multi-word term splits on the existing space too; the space-joined form equals the canonical
        // ("feature flag") so it is dropped (already a form), leaving the hyphen + run-on derivations.
        XCTAssertEqual(DictionaryMatcher.Rule.derivedSpokenForms(from: "feature flag"),
                       ["feature-flag", "featureflag"])
        // Single-segment terms derive nothing.
        XCTAssertEqual(DictionaryMatcher.Rule.derivedSpokenForms(from: "codex"), [])
        XCTAssertEqual(DictionaryMatcher.Rule.derivedSpokenForms(from: "GPT"), [])
        XCTAssertEqual(DictionaryMatcher.Rule.derivedSpokenForms(from: "拓荆科技"), [])
    }
}
