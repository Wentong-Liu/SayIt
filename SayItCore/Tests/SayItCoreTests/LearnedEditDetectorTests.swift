import XCTest
@testable import SayItCore

/// Heavy-TDD coverage for the pure ``LearnedEditDetector/suggestion(injected:edited:)`` guardrails.
///
/// The detector is intentionally conservative: it only fires on an exact single-token substitution that also passes the
/// proper-noun/uncommon stoplist guard and the similarity guard. These tests pin every required acceptance/rejection case.
final class LearnedEditDetectorTests: XCTestCase {

    // MARK: - Suggestions (positive cases)

    func testSingleSubstitutionProperNounYieldsSuggestion() {
        let result = LearnedEditDetector.suggestion(injected: "I met jon today", edited: "I met John today")
        XCTAssertEqual(result?.heard, "jon")
        XCTAssertEqual(result?.corrected, "John")
    }

    func testUncommonCodeTermYieldsSuggestion() {
        let result = LearnedEditDetector.suggestion(injected: "the useffect hook", edited: "the useEffect hook")
        XCTAssertEqual(result?.heard, "useffect")
        XCTAssertEqual(result?.corrected, "useEffect")
    }

    func testCasingOnlyProperNounYieldsSuggestion() {
        let result = LearnedEditDetector.suggestion(injected: "we love sequoia", edited: "we love Sequoia")
        XCTAssertEqual(result?.heard, "sequoia")
        XCTAssertEqual(result?.corrected, "Sequoia")
    }

    func testTokenizerStripsTrailingPunctuation() {
        // The trailing period must be trimmed so the substitution is detected on the bare word.
        let result = LearnedEditDetector.suggestion(injected: "hi jon.", edited: "hi John.")
        XCTAssertEqual(result?.heard, "jon")
        XCTAssertEqual(result?.corrected, "John")
    }

    // MARK: - Rejections (negative cases)

    func testMultiTokenEditReturnsNil() {
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "the quick brown fox",
                                                    edited: "a slow brown fox"))
    }

    func testCommonWordEditReturnsNil() {
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "the cat sat", edited: "the dog sat"))
    }

    func testIdenticalReturnsNil() {
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "I met John today",
                                                    edited: "I met John today"))
    }

    func testPureInsertionReturnsNil() {
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "hello world",
                                                    edited: "hello there world"))
    }

    func testPureDeletionReturnsNil() {
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "hello there world",
                                                    edited: "hello world"))
    }

    func testCommonWordCasingOnlyReturnsNil() {
        // Sentence-initial capitalisation of a common word must NOT be learned.
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "the cat", edited: "The cat"))
    }

    func testDissimilarSingleSubstitutionFailsSimilarityGuard() {
        // Both made-up words escape the stoplist, but they are not plausibly the same word -> similarity guard rejects.
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "buy zorp now", edited: "buy quux now"))
    }

    func testEmptyStringsReturnNil() {
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "", edited: ""))
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "", edited: "John"))
        XCTAssertNil(LearnedEditDetector.suggestion(injected: "John", edited: ""))
    }

    // MARK: - Tokenizer unit behavior

    func testTokenizerKeepsInternalPunctuationDropsEdges() {
        XCTAssertEqual(LearnedEditDetector.tokenize("hi, (useEffect) O'Brien."),
                       ["hi", "useEffect", "O'Brien"])
    }

    func testTokenizerCollapsesWhitespace() {
        XCTAssertEqual(LearnedEditDetector.tokenize("  one   two\tthree\n"), ["one", "two", "three"])
    }

    // MARK: - Heuristic unit behavior

    func testProperNounDetection() {
        XCTAssertTrue(LearnedEditDetector.looksLikeProperNoun("John"))
        XCTAssertTrue(LearnedEditDetector.looksLikeProperNoun("useEffect"))
        XCTAssertTrue(LearnedEditDetector.looksLikeProperNoun("iPhone"))
        XCTAssertFalse(LearnedEditDetector.looksLikeProperNoun("john"))
        XCTAssertFalse(LearnedEditDetector.looksLikeProperNoun(""))
    }

    func testCommonWordDetectionIsCaseInsensitive() {
        XCTAssertTrue(LearnedEditDetector.isCommonWord("cat"))
        XCTAssertTrue(LearnedEditDetector.isCommonWord("The"))
        XCTAssertFalse(LearnedEditDetector.isCommonWord("Sequoia"))
    }

    func testSimilarityAcceptsCloseRejectsFar() {
        XCTAssertTrue(LearnedEditDetector.areSimilar("jon", "John"))
        XCTAssertTrue(LearnedEditDetector.areSimilar("sequoia", "Sequoia"))
        XCTAssertFalse(LearnedEditDetector.areSimilar("cat", "elephant"))
        XCTAssertFalse(LearnedEditDetector.areSimilar("zorp", "quux"))
    }

    func testLevenshteinBasics() {
        XCTAssertEqual(LearnedEditDetector.levenshtein("", ""), 0)
        XCTAssertEqual(LearnedEditDetector.levenshtein("abc", "abc"), 0)
        XCTAssertEqual(LearnedEditDetector.levenshtein("abc", "abd"), 1)
        XCTAssertEqual(LearnedEditDetector.levenshtein("kitten", "sitting"), 3)
    }
}
