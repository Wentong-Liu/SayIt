import WhisperKit
import XCTest
@testable import SayItCore

/// A lightweight unit test not depending on model download/load: covers initialization, input guards, pure mapping logic.
/// Real transcription (requiring fetching the model online + Core ML inference) is left to the integration stage for on-device verification.
final class WhisperKitTranscriberTests: XCTestCase {
    // MARK: - Initialization

    func testDefaultModelIsLargeV3Turbo() {
        let stt = WhisperKitTranscriber()
        XCTAssertEqual(stt.model, "large-v3-turbo")
    }

    func testCustomModelIsStored() {
        let stt = WhisperKitTranscriber(model: "base.en")
        XCTAssertEqual(stt.model, "base.en")
    }

    func testRequiredSampleRateIs16k() {
        XCTAssertEqual(WhisperKitTranscriber.requiredSampleRate, 16_000)
    }

    func testIsReadyFalseBeforeLoad() async {
        let stt = WhisperKitTranscriber()
        let ready = await stt.isReady
        XCTAssertFalse(ready)
    }

    // MARK: - Input guards (return before loading the model, triggering no download)

    func testEmptyAudioThrowsEmptyAudioError() async {
        let stt = WhisperKitTranscriber()
        do {
            _ = try await stt.transcribe([], sampleRate: 16_000, language: nil)
            XCTFail("expected STTError.emptyAudio")
        } catch let error as STTError {
            XCTAssertEqual(error, STTError.emptyAudio)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testWrongSampleRateThrowsUnsupportedFormat() async {
        let stt = WhisperKitTranscriber()
        do {
            _ = try await stt.transcribe([0.1, 0.2], sampleRate: 44_100, language: nil)
            XCTFail("expected STTError.unsupportedFormat")
        } catch let error as STTError {
            XCTAssertEqual(error, STTError.unsupportedFormat)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Pure mapping logic mapResult

    func testMapResultTrimsAndJoins() {
        let result = WhisperKitTranscriber.mapResult(
            joinedText: "  hello world  ",
            segments: []
        )
        XCTAssertEqual(result.text, "hello world")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNil(result.duration)
    }

    func testMapResultBuildsSegmentsAndDuration() {
        let raw = [
            WhisperKitTranscriber.RawSegment(text: " hello", start: 0, end: 1.2),
            WhisperKitTranscriber.RawSegment(text: "world ", start: 1.2, end: 2.4),
        ]
        let result = WhisperKitTranscriber.mapResult(joinedText: " hello world ", segments: raw)

        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "hello")
        XCTAssertEqual(result.segments[0].start, 0)
        XCTAssertEqual(result.segments[0].end, 1.2)
        XCTAssertEqual(result.segments[1].text, "world")
        XCTAssertEqual(result.duration, 2.4, "duration should take the end of the last segment")
    }

    func testMapResultEmptyEverything() {
        let result = WhisperKitTranscriber.mapResult(joinedText: "", segments: [])
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNil(result.duration)
    }

    func testMapResultCollapsesInternalDoubleSpaces() {
        // Chunked concatenation (each segment carrying its own leading/trailing spaces, joined with " ") produces double spaces; mapResult should collapse them to a single space.
        let result = WhisperKitTranscriber.mapResult(
            joinedText: "hello   world  again",
            segments: []
        )
        XCTAssertEqual(result.text, "hello world again")
    }

    func testMapResultCollapsesNewlinesAndTabs() {
        let result = WhisperKitTranscriber.mapResult(
            joinedText: "  foo\t\tbar\n\nbaz  ",
            segments: []
        )
        XCTAssertEqual(result.text, "foo bar baz")
    }

    func testCollapseWhitespaceLeavesSingleSpacedTextUnchanged() {
        XCTAssertEqual(WhisperKitTranscriber.collapseWhitespace("a b c"), "a b c")
    }

    // MARK: - DecodingOptions construction (language auto-detection regression protection)

    // Regression: the user spoke Chinese but it was transcribed/translated into English. The root cause is that with language==nil and detectLanguage off,
    // WhisperKit skips language detection in TranscribeTask and falls back to Constants.defaultLanguageCode ("en"),
    // thus decoding as English. The cases below lock down "nil language => auto-detect" and "task is always transcribe (never translate)".

    func testDecodingOptionsAutoDetectsLanguageWhenNil() {
        let options = WhisperKitTranscriber.makeDecodingOptions(language: nil)
        XCTAssertTrue(
            options.detectLanguage,
            "when language==nil auto-detection must be enabled, otherwise WhisperKit decodes as English by default (Chinese would be turned into English)"
        )
        XCTAssertNil(options.language, "no language code should be forced when none is specified")
    }

    func testDecodingOptionsTaskIsTranscribeNeverTranslate() {
        let detectOptions = WhisperKitTranscriber.makeDecodingOptions(language: nil)
        let explicitOptions = WhisperKitTranscriber.makeDecodingOptions(language: "zh")
        XCTAssertEqual(detectOptions.task, .transcribe, "must transcribe in the original language, never translate")
        XCTAssertEqual(explicitOptions.task, .transcribe, "must transcribe in the original language, never translate")
    }

    func testDecodingOptionsPassesThroughExplicitLanguage() {
        let options = WhisperKitTranscriber.makeDecodingOptions(language: "zh")
        XCTAssertEqual(options.language, "zh", "an explicitly specified language code should be passed through as-is")
        XCTAssertFalse(options.detectLanguage, "auto-detection is unnecessary once the language is explicitly specified")
    }

    // MARK: - Layer 1 biasing: makeDecodingOptions(promptTokens:)

    func testDecodingOptionsNoPromptKeepsDefaultThreshold() {
        // No prompt tokens: promptTokens stays nil and firstTokenLogProbThreshold keeps WhisperKit's -1.5 default (byte-identical to today).
        let none = WhisperKitTranscriber.makeDecodingOptions(language: nil)
        XCTAssertNil(none.promptTokens, "promptTokens should not be set when there are no biasing terms")
        XCTAssertEqual(none.firstTokenLogProbThreshold, DecodingOptions().firstTokenLogProbThreshold,
                       "firstTokenLogProbThreshold should keep WhisperKit's default when there are no biasing terms")

        let emptyPrompt = WhisperKitTranscriber.makeDecodingOptions(language: "en", promptTokens: [])
        XCTAssertNil(emptyPrompt.promptTokens, "empty promptTokens is equivalent to no biasing")
        XCTAssertEqual(emptyPrompt.firstTokenLogProbThreshold, DecodingOptions().firstTokenLogProbThreshold,
                       "firstTokenLogProbThreshold should keep the default when promptTokens is empty")
    }

    func testDecodingOptionsWithPromptDisablesFirstTokenThreshold() {
        // Issue #372 mitigation: a non-empty promptTokens sets the tokens AND nils firstTokenLogProbThreshold
        // (otherwise on turbo the first-token logprob can break the decode loop early -> empty transcription).
        let options = WhisperKitTranscriber.makeDecodingOptions(language: "en", promptTokens: [10, 20, 30])
        XCTAssertEqual(options.promptTokens, [10, 20, 30], "non-empty biasing terms should be written into promptTokens as-is")
        XCTAssertNil(options.firstTokenLogProbThreshold,
                     "when promptTokens is set, firstTokenLogProbThreshold must be set to nil to avoid WhisperKit #372 empty transcription")
        XCTAssertEqual(options.task, .transcribe, "biasing should not change the task; it must still be transcribe")
    }

    // MARK: - Layer 1 biasing: promptTokens(from:tokenizer:)

    func testPromptTokensEmptyTermsYieldsEmpty() {
        let tokenizer = StubTokenizer(specialTokenBegin: 1000)
        XCTAssertEqual(WhisperKitTranscriber.promptTokens(from: [], tokenizer: tokenizer), [])
        XCTAssertEqual(WhisperKitTranscriber.promptTokens(from: ["   ", ""], tokenizer: tokenizer), [],
                       "all-whitespace terms should be dropped, yielding an empty token list (no biasing triggered)")
    }

    func testPromptTokensFiltersSpecialTokens() {
        // The stub maps each character to its ASCII code; we craft a glossary whose encoding includes a special id (>= begin).
        // Special tokens (id >= specialTokenBegin) must be filtered out so only real word-piece ids remain.
        let tokenizer = StubTokenizer(specialTokenBegin: 100, encoder: { _ in [5, 100, 42, 250, 7] })
        let tokens = WhisperKitTranscriber.promptTokens(from: ["foo"], tokenizer: tokenizer)
        XCTAssertEqual(tokens, [5, 42, 7], "special tokens with id >= specialTokenBegin must be filtered out")
    }

    func testPromptTokensCapsToLastMaxTokens() {
        // Encoding produces 0..<300; with a cap of 200 we keep the LAST 200 (the highest-priority suffix), i.e. 100..<300.
        let tokenizer = StubTokenizer(specialTokenBegin: 100_000, encoder: { _ in Array(0..<300) })
        let tokens = WhisperKitTranscriber.promptTokens(from: ["anything"], tokenizer: tokenizer, maxTokens: 200)
        XCTAssertEqual(tokens.count, 200)
        XCTAssertEqual(tokens.first, 100, "when over the cap keep the suffix (the most relevant is at the tail); the first element should be the 100th after trimming the prefix")
        XCTAssertEqual(tokens.last, 299)
    }

    func testPromptTokensUnderCapKeepsAll() {
        let tokenizer = StubTokenizer(specialTokenBegin: 100_000, encoder: { _ in [1, 2, 3] })
        let tokens = WhisperKitTranscriber.promptTokens(from: ["term"], tokenizer: tokenizer, maxTokens: 200)
        XCTAssertEqual(tokens, [1, 2, 3], "all tokens should be kept when under the cap")
    }

    func testPromptTokensDefaultCapIs111() {
        // The default cap is now 111 (WhisperKit's real effective maxPromptLen = (maxTokenContext/2)-1 = 111).
        // Calling WITHOUT maxTokens and feeding >111 tokens must keep the LAST 111 (the highest-usage suffix).
        let tokenizer = StubTokenizer(specialTokenBegin: 100_000, encoder: { _ in Array(0..<300) })
        let tokens = WhisperKitTranscriber.promptTokens(from: ["anything"], tokenizer: tokenizer)
        XCTAssertEqual(tokens.count, 111, "the default cap should be 111 (WhisperKit's real effective limit)")
        XCTAssertEqual(tokens.first, 189, "when over the cap keep the suffix; the first element should be the 189th after trimming the first 189 (300-111)")
        XCTAssertEqual(tokens.last, 299, "the last token (the most relevant tail) should be kept")
    }

    func testPromptTokensDefaultCapKeepsAllUnder111() {
        let tokenizer = StubTokenizer(specialTokenBegin: 100_000, encoder: { _ in Array(0..<111) })
        let tokens = WhisperKitTranscriber.promptTokens(from: ["term"], tokenizer: tokenizer)
        XCTAssertEqual(tokens.count, 111, "exactly 111 tokens are all kept (not over the cap)")
        XCTAssertEqual(tokens, Array(0..<111))
    }

    // MARK: - Protocol conformance

    func testUsableThroughTranscriberExistential() {
        let _: any Transcriber = WhisperKitTranscriber()
    }
}

// MARK: - Test stub

/// A minimal in-memory ``WhisperTokenizer`` for unit-testing the pure biasing helpers without loading a real model.
/// Only the members the helpers touch (`encode`, `specialTokens`) are meaningful; the rest are trivial stubs.
private struct StubTokenizer: WhisperTokenizer {
    let specialTokens: SpecialTokens
    let encoder: @Sendable (String) -> [Int]

    init(specialTokenBegin: Int, encoder: @escaping @Sendable (String) -> [Int] = { text in text.unicodeScalars.map { Int($0.value) } }) {
        self.encoder = encoder
        self.specialTokens = SpecialTokens(
            endToken: specialTokenBegin,
            englishToken: specialTokenBegin,
            noSpeechToken: specialTokenBegin,
            noTimestampsToken: specialTokenBegin,
            specialTokenBegin: specialTokenBegin,
            startOfPreviousToken: specialTokenBegin,
            startOfTranscriptToken: specialTokenBegin,
            timeTokenBegin: specialTokenBegin,
            transcribeToken: specialTokenBegin,
            translateToken: specialTokenBegin,
            whitespaceToken: specialTokenBegin
        )
    }

    func encode(text: String) -> [Int] { encoder(text) }
    func decode(tokens: [Int]) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var allLanguageTokens: Set<Int> { [] }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) { ([], []) }
}
