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

    // MARK: - NO auto-derivation of spoken forms (single-word model: NO user-supplied variants)
    //
    // Product decision: the deterministic Layer 3 must NOT guess multi-word spoken forms from the canonical spelling.
    // A single-word entry matches its canonical only via exact / case-insensitive / joined-lowercase (single token).
    // Context-aware "spoken phrase -> term" conversion (e.g. `use effect` -> `useEffect`) is delegated to the LLM
    // (Layer 2 injects the glossary + transcript into the polish prompt). These tests invert the former T55 behavior.

    func testCanonicalWithoutVariantsMatchesExactCaseInsensitiveAndJoinedOnly() {
        // Only the canonical "useEffect" — no variants.
        let entry = DictionaryEntry(canonical: "useEffect")
        XCTAssertEqual(entry.variants, [], "precondition: this entry supplies no variants")
        // (a) exact case-sensitive spelling stays canonical.
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call useEffect here", using: [entry]), "Call useEffect here")
        // (b) case-insensitive (all-caps) of the canonical normalizes to the stored casing.
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call USEEFFECT here", using: [entry]), "Call useEffect here",
                       "case-insensitive: an all-caps spelling normalizes to the canonical")
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call UseEffect here", using: [entry]), "Call useEffect here",
                       "case-insensitive: the PascalCase spelling normalizes to the canonical")
        // (c) the joined-lowercase run-on single token normalizes to the canonical.
        XCTAssertEqual(DictionaryRewriter.apply(to: "the useeffect hook", using: [entry]), "the useEffect hook")
        // NOT a two-word spoken phrase — that is the LLM's job, the deterministic layer leaves it untouched.
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call use effect here", using: [entry]), "Call use effect here",
                       "no auto-derivation: the two-word phrase 'use effect' must NOT be rewritten")
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call use-effect here", using: [entry]), "Call use-effect here",
                       "no auto-derivation: the hyphenated phrase 'use-effect' must NOT be rewritten")
    }

    func testNoOverCorrectionForIOSEntry() {
        // The canonical reported in the audit (HIGH #1): an `iOS` entry must NOT rewrite the ordinary phrase 'i os'.
        let entry = DictionaryEntry(canonical: "iOS")
        XCTAssertEqual(DictionaryRewriter.apply(to: "i os here", using: [entry]), "i os here",
                       "no auto-derivation: 'i os' must NOT become 'iOS'")
        // The canonical and its case-insensitive / joined forms still normalize.
        XCTAssertEqual(DictionaryRewriter.apply(to: "the iOS app", using: [entry]), "the iOS app")
        XCTAssertEqual(DictionaryRewriter.apply(to: "the IOS app", using: [entry]), "the iOS app",
                       "case-insensitive normalizes to the stored casing")
        XCTAssertEqual(DictionaryRewriter.apply(to: "the ios app", using: [entry]), "the iOS app",
                       "joined single-token lowercase normalizes to the stored casing")
    }

    func testNoOverCorrectionForMacOSEntry() {
        let entry = DictionaryEntry(canonical: "macOS")
        XCTAssertEqual(DictionaryRewriter.apply(to: "on mac os today", using: [entry]), "on mac os today",
                       "no auto-derivation: 'mac os' must NOT become 'macOS'")
        XCTAssertEqual(DictionaryRewriter.apply(to: "on macos today", using: [entry]), "on macOS today",
                       "joined single-token lowercase still normalizes")
    }

    func testNoOverCorrectionForOAuth2Entry() {
        let entry = DictionaryEntry(canonical: "OAuth2")
        XCTAssertEqual(DictionaryRewriter.apply(to: "use o auth 2 flow", using: [entry]), "use o auth 2 flow",
                       "no auto-derivation: 'o auth 2' must NOT become 'OAuth2'")
        XCTAssertEqual(DictionaryRewriter.apply(to: "use oauth2 flow", using: [entry]), "use OAuth2 flow",
                       "joined single-token lowercase still normalizes")
    }

    func testNoOverCorrectionForPascalCaseBigQuery() {
        // BigQuery: no variants supplied -> 'big query' / 'big-query' must NOT be rewritten.
        let entry = DictionaryEntry(canonical: "BigQuery")
        XCTAssertEqual(DictionaryRewriter.apply(to: "load it into big query now", using: [entry]),
                       "load it into big query now",
                       "no auto-derivation: 'big query' must NOT become 'BigQuery'")
        XCTAssertEqual(DictionaryRewriter.apply(to: "load it into big-query now", using: [entry]),
                       "load it into big-query now",
                       "no auto-derivation: 'big-query' must NOT become 'BigQuery'")
        XCTAssertEqual(DictionaryRewriter.apply(to: "load it into bigquery now", using: [entry]),
                       "load it into BigQuery now", "joined single-token lowercase still normalizes")
        XCTAssertEqual(DictionaryRewriter.apply(to: "load it into BigQuery now", using: [entry]),
                       "load it into BigQuery now", "the canonical itself stays canonical")
    }

    func testNoOverCorrectionForAcronymWordBoundary() {
        // HTTPServer: no variants -> 'http server' must NOT be rewritten (no fabricated upper-run boundary split).
        let entry = DictionaryEntry(canonical: "HTTPServer")
        XCTAssertEqual(DictionaryRewriter.apply(to: "start the http server please", using: [entry]),
                       "start the http server please",
                       "no auto-derivation: 'http server' must NOT become 'HTTPServer'")
        XCTAssertEqual(DictionaryRewriter.apply(to: "start the httpserver please", using: [entry]),
                       "start the HTTPServer please", "joined single-token lowercase still normalizes")
    }

    func testNoFabricationForPlainLowercaseTerm() {
        // codex: single all-lowercase token -> exact/case-insensitive only, no over-correction.
        let entry = DictionaryEntry(canonical: "codex")
        XCTAssertEqual(DictionaryRewriter.apply(to: "open codex now", using: [entry]), "open codex now",
                       "the canonical matches itself (identity)")
        XCTAssertEqual(DictionaryRewriter.apply(to: "open CODEX now", using: [entry]), "open codex now",
                       "case-insensitive normalizes to canonical")
        XCTAssertEqual(DictionaryRewriter.apply(to: "write code here", using: [entry]), "write code here",
                       "the unrelated word 'code' must not be touched (no fabricated variants)")
    }

    func testNoFabricationForAllCapsTerm() {
        // GPT: single all-caps token -> "g p t" must not become "GPT".
        let entry = DictionaryEntry(canonical: "GPT")
        XCTAssertEqual(DictionaryRewriter.apply(to: "use GPT now", using: [entry]), "use GPT now")
        XCTAssertEqual(DictionaryRewriter.apply(to: "use gpt now", using: [entry]), "use GPT now",
                       "case-insensitive normalizes to canonical")
        XCTAssertEqual(DictionaryRewriter.apply(to: "g p t spelled out", using: [entry]), "g p t spelled out",
                       "an all-caps acronym derives no spoken multi-word form")
    }

    func testNoFabricationForChineseTerm() {
        // A CJK term has no case boundaries -> matches exactly, unrelated text untouched.
        let entry = DictionaryEntry(canonical: "拓荆科技")
        XCTAssertEqual(DictionaryRewriter.apply(to: "我在拓荆科技工作", using: [entry]), "我在拓荆科技工作")
        XCTAssertEqual(DictionaryRewriter.apply(to: "今天天气不错", using: [entry]), "今天天气不错",
                       "unrelated Chinese text is untouched (no fabricated variants)")
    }

    // MARK: - Explicit variants ARE still honored (deliberate user mappings)

    func testExplicitTwoWordVariantStillRewritesPhrase() {
        // A user-confirmed variant 'use effect' is a deliberate mapping: the two-word phrase DOES still rewrite.
        let entry = DictionaryEntry(canonical: "useEffect", variants: ["use effect"])
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call use effect here", using: [entry]), "Call useEffect here",
                       "explicit variant 'use effect' is preserved and still merges")
        // The hyphenated spelling of the same explicit variant also merges (whitespace/hyphen normalized to one key).
        XCTAssertEqual(DictionaryRewriter.apply(to: "Call use-effect here", using: [entry]), "Call useEffect here",
                       "the explicit variant normalizes across the hyphen too")
        // And the canonical's joined-lowercase single token still works.
        XCTAssertEqual(DictionaryRewriter.apply(to: "the useeffect hook", using: [entry]), "the useEffect hook")
    }

    func testExplicitVariantDoesNotEnableUnrelatedPhrases() {
        // The explicit variant only maps its own phrase (by normalized key); a phrase with a different key is untouched.
        // Note: a variant collapses whitespace/hyphens into a single normalized key, so 'i o s' and 'i os' share the
        // key "ios" and both legitimately map — that is the intended explicit-variant behavior. To prove the canonical
        // alone does NOT fabricate a phrase mapping, we declare a variant only for one phrase and dictate another.
        let entry = DictionaryEntry(canonical: "iOS", variants: ["eye o s"])
        XCTAssertEqual(DictionaryRewriter.apply(to: "eye o s here", using: [entry]), "iOS here",
                       "the explicit variant 'eye o s' is a deliberate mapping and rewrites")
        XCTAssertEqual(DictionaryRewriter.apply(to: "i os here", using: [entry]), "i os here",
                       "the phrase 'i os' is not the declared variant and the canonical never fabricates a phrase mapping")
    }

    func testDeterministicWithExplicitVariant() {
        let entry = DictionaryEntry(canonical: "useEffect", variants: ["use effect"])
        let input = "wrap use effect and use effect together"
        let first = DictionaryRewriter.apply(to: input, using: [entry])
        let second = DictionaryRewriter.apply(to: input, using: [entry])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "wrap useEffect and useEffect together")
    }
}
