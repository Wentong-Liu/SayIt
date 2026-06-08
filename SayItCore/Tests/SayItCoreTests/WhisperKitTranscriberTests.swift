import Foundation
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

    // MARK: - Sole-downloader contract: load (never download) a present model; fail cleanly when absent

    /// ``ModelManager/download(model:)`` is the sole downloader; this engine only LOADS an already-present local model and
    /// must NEVER start a competing download (the second-downloader race that froze the "preparing model" HUD). When the
    /// model is genuinely absent from the local cache, ``preload()`` (→ `loadedEngine()`) must fail CLEANLY with
    /// ``STTError/notReady`` WITHOUT touching the network. A model name that maps to a variant folder that cannot exist in
    /// the cache (a per-run UUID) guarantees "absent" regardless of which real models happen to be cached on the test
    /// machine, and the network-free ``ModelManager/cachedModelFolder(for:)`` short-circuits before any WhisperKit/Hub call.
    func testPreloadThrowsNotReadyWhenModelAbsentAndNeverDownloads() async {
        let absentModel = "sayit-absent-\(UUID().uuidString)"
        // Precondition: this model truly is not cached locally (so the test exercises the absent path deterministically).
        XCTAssertNil(ModelManager.cachedModelFolder(for: absentModel),
                     "the per-run UUID model must not be present in the local cache")
        XCTAssertFalse(ModelManager.isDownloaded(model: absentModel),
                       "an absent model must not be reported as downloaded")

        let stt = WhisperKitTranscriber(model: absentModel)
        do {
            try await stt.preload()
            XCTFail("expected STTError.notReady for an absent model (must not download)")
        } catch let error as STTError {
            XCTAssertEqual(error, STTError.notReady,
                           "an absent model must fail cleanly with .notReady, never silently downloading")
        } catch {
            XCTFail("unexpected error type (a network/download error would mean the engine wrongly tried to download): \(error)")
        }
        // The clean failure must not have constructed/loaded an engine.
        let ready = await stt.isReady
        XCTAssertFalse(ready, "a failed load must leave the engine unloaded")
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

    func testCarrierOnlyPromptDisablesFirstTokenThreshold() {
        // The carrier-only path (no dict terms) is now a real, non-empty prompt -> the #372 mitigation must extend to it:
        // feeding the carrier-only tokens into makeDecodingOptions must nil firstTokenLogProbThreshold.
        let tokenizer = StubTokenizer(specialTokenBegin: 1_000_000)
        let carrierTokens = WhisperKitTranscriber.promptTokens(from: [], tokenizer: tokenizer)
        XCTAssertFalse(carrierTokens.isEmpty, "the carrier-only prompt must be non-empty")
        let prompted = WhisperKitTranscriber.makeDecodingOptions(language: nil, promptTokens: carrierTokens)
        XCTAssertNil(prompted.firstTokenLogProbThreshold,
                     "the always-on carrier prompt must nil firstTokenLogProbThreshold just like a dict-term prompt (#372)")
        // And when there is TRULY no prompt (nil promptTokens, e.g. tokenizer unavailable), the default is preserved.
        let unprompted = WhisperKitTranscriber.makeDecodingOptions(language: nil, promptTokens: nil)
        XCTAssertEqual(unprompted.firstTokenLogProbThreshold, DecodingOptions().firstTokenLogProbThreshold,
                       "with no prompt at all the WhisperKit -1.5 default must be preserved")
    }

    // MARK: - Layer 1 biasing: promptTokens(from:tokenizer:)

    // Contract INVERSION (punctuation feature): with no dictionary terms the prompt is no longer empty — the always-on
    // punctuation carrier is built instead, so the free/local path is still prompted and gets the punctuation nudge.
    // (This test replaces the former `testPromptTokensEmptyTermsYieldsEmpty`, whose empty-output contract this feature
    // intentionally reverses.)
    func testPromptTokensEmptyTermsYieldsCarrierTokens() {
        let tokenizer = StubTokenizer(specialTokenBegin: 1_000_000)
        // No terms: the carrier alone is tokenized -> a NON-empty token list (default unicode-scalar stub encoder).
        XCTAssertFalse(WhisperKitTranscriber.promptTokens(from: [], tokenizer: tokenizer).isEmpty,
                       "with no terms the always-on punctuation carrier should still produce a non-empty token list")
        // All-whitespace terms collapse to no dictionary terms -> still just the carrier (non-empty), never [].
        XCTAssertFalse(WhisperKitTranscriber.promptTokens(from: ["   ", ""], tokenizer: tokenizer).isEmpty,
                       "all-blank terms drop to no glossary, but the carrier keeps the token list non-empty")
    }

    func testCarrierConstantHasNoHyphen() {
        XCTAssertFalse(WhisperKitTranscriber.punctuationCarrier.contains("-"),
                       "the carrier must contain no hyphen so it never nudges word-internal hyphenation (e.g. Typeless -> Type-less)")
        // It should carry both Chinese and English sentence punctuation (it biases STYLE across both auto-detected languages).
        for mark in ["。", "，", ".", ","] {
            XCTAssertTrue(WhisperKitTranscriber.punctuationCarrier.contains(mark),
                          "the carrier should contain the sentence punctuation mark \(mark)")
        }
    }

    func testBuiltPromptKeepsTermVerbatimAndIncludesCarrier() {
        // The composed prompt text must contain "Typeless" UNALTERED (no hyphen, no case change) and the carrier.
        let prompt = WhisperKitTranscriber.promptText(forTerms: ["Typeless"])
        XCTAssertTrue(prompt.contains("Typeless"), "the dictionary term must appear verbatim in the built prompt")
        XCTAssertFalse(prompt.contains("Type-less"), "no hyphen may be inserted into the term")
        XCTAssertTrue(prompt.contains(WhisperKitTranscriber.punctuationCarrier),
                      "the punctuation carrier must be present as the prompt prefix")
        XCTAssertTrue(prompt.hasSuffix("."), "the dictionary term list should be closed by a trailing period")
        // No-terms case is just the carrier itself (self-punctuated).
        XCTAssertEqual(WhisperKitTranscriber.promptText(forTerms: []), WhisperKitTranscriber.punctuationCarrier)
    }

    func testBuiltPromptCapturesExactTermTextViaEncoder() {
        // Capture the exact string handed to encode(text:) to prove the term reaches the tokenizer character-for-character.
        let captured = CapturedText()
        let tokenizer = StubTokenizer(specialTokenBegin: 1_000_000, encoder: { text in
            captured.value = text
            return text.unicodeScalars.map { Int($0.value) }
        })
        _ = WhisperKitTranscriber.promptTokens(from: ["useEffect"], tokenizer: tokenizer)
        XCTAssertTrue(captured.value.contains("useEffect"),
                      "the tokenizer must receive the term verbatim — no hyphen, no case change")
        XCTAssertFalse(captured.value.contains("use-Effect"))
        XCTAssertTrue(captured.value.contains(WhisperKitTranscriber.punctuationCarrier),
                      "the tokenizer input must include the punctuation carrier")
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

    func testCombinedCarrierPlusTermsPromptRespects111Cap() {
        // The COMBINED prompt (carrier + dict terms) is tokenized as one string. With an encoder returning >111 ids,
        // the suffix-keep semantics must hold: keep exactly the LAST 111 (the highest-priority tail = most-relevant terms).
        let tokenizer = StubTokenizer(specialTokenBegin: 1_000_000, encoder: { _ in Array(0..<300) })
        let tokens = WhisperKitTranscriber.promptTokens(from: ["Typeless", "useEffect"], tokenizer: tokenizer)
        XCTAssertEqual(tokens.count, 111, "the combined carrier+terms prompt must still be capped at 111")
        XCTAssertEqual(tokens.first, 189, "suffix-keep: the first surviving token is the 189th (300-111)")
        XCTAssertEqual(tokens.last, 299, "the most-relevant tail (the suffix) must survive the cap")
    }

    // MARK: - Protocol conformance

    func testUsableThroughTranscriberExistential() {
        let _: any Transcriber = WhisperKitTranscriber()
    }
}

// MARK: - Test helpers

/// A tiny lock-guarded box used to capture the exact text handed to a `@Sendable` stub encoder closure, so a test can
/// assert on the precise string the tokenizer received (proving terms reach it verbatim). `@unchecked Sendable` is sound
/// here because every access is serialized behind the lock.
private final class CapturedText: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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
