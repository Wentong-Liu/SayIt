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
        XCTAssertEqual(result.duration, 2.4, "duration 应取最后一个分段的 end")
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
            "language==nil 时必须开启自动检测，否则 WhisperKit 默认按英文解码（中文会被转成英文）"
        )
        XCTAssertNil(options.language, "未指定语言时不应硬塞一个语言码")
    }

    func testDecodingOptionsTaskIsTranscribeNeverTranslate() {
        let detectOptions = WhisperKitTranscriber.makeDecodingOptions(language: nil)
        let explicitOptions = WhisperKitTranscriber.makeDecodingOptions(language: "zh")
        XCTAssertEqual(detectOptions.task, .transcribe, "必须转写为原语言，绝不能翻译")
        XCTAssertEqual(explicitOptions.task, .transcribe, "必须转写为原语言，绝不能翻译")
    }

    func testDecodingOptionsPassesThroughExplicitLanguage() {
        let options = WhisperKitTranscriber.makeDecodingOptions(language: "zh")
        XCTAssertEqual(options.language, "zh", "显式指定的语言码应原样透传")
        XCTAssertFalse(options.detectLanguage, "已显式指定语言时无需再自动检测")
    }

    // MARK: - Layer 1 biasing: makeDecodingOptions(promptTokens:)

    func testDecodingOptionsNoPromptKeepsDefaultThreshold() {
        // No prompt tokens: promptTokens stays nil and firstTokenLogProbThreshold keeps WhisperKit's -1.5 default (byte-identical to today).
        let none = WhisperKitTranscriber.makeDecodingOptions(language: nil)
        XCTAssertNil(none.promptTokens, "无偏置词时不应设置 promptTokens")
        XCTAssertEqual(none.firstTokenLogProbThreshold, DecodingOptions().firstTokenLogProbThreshold,
                       "无偏置词时 firstTokenLogProbThreshold 应保持 WhisperKit 默认值")

        let emptyPrompt = WhisperKitTranscriber.makeDecodingOptions(language: "en", promptTokens: [])
        XCTAssertNil(emptyPrompt.promptTokens, "空 promptTokens 等同无偏置")
        XCTAssertEqual(emptyPrompt.firstTokenLogProbThreshold, DecodingOptions().firstTokenLogProbThreshold,
                       "空 promptTokens 时 firstTokenLogProbThreshold 应保持默认值")
    }

    func testDecodingOptionsWithPromptDisablesFirstTokenThreshold() {
        // Issue #372 mitigation: a non-empty promptTokens sets the tokens AND nils firstTokenLogProbThreshold
        // (otherwise on turbo the first-token logprob can break the decode loop early -> empty transcription).
        let options = WhisperKitTranscriber.makeDecodingOptions(language: "en", promptTokens: [10, 20, 30])
        XCTAssertEqual(options.promptTokens, [10, 20, 30], "非空偏置词应原样写入 promptTokens")
        XCTAssertNil(options.firstTokenLogProbThreshold,
                     "设置 promptTokens 时必须把 firstTokenLogProbThreshold 设为 nil，规避 WhisperKit #372 空转写")
        XCTAssertEqual(options.task, .transcribe, "偏置不应改变 task，仍必须是 transcribe")
    }

    // MARK: - Layer 1 biasing: promptTokens(from:tokenizer:)

    func testPromptTokensEmptyTermsYieldsEmpty() {
        let tokenizer = StubTokenizer(specialTokenBegin: 1000)
        XCTAssertEqual(WhisperKitTranscriber.promptTokens(from: [], tokenizer: tokenizer), [])
        XCTAssertEqual(WhisperKitTranscriber.promptTokens(from: ["   ", ""], tokenizer: tokenizer), [],
                       "全空白词应被丢弃，得到空 token 列表（不会触发偏置）")
    }

    func testPromptTokensFiltersSpecialTokens() {
        // The stub maps each character to its ASCII code; we craft a glossary whose encoding includes a special id (>= begin).
        // Special tokens (id >= specialTokenBegin) must be filtered out so only real word-piece ids remain.
        let tokenizer = StubTokenizer(specialTokenBegin: 100, encoder: { _ in [5, 100, 42, 250, 7] })
        let tokens = WhisperKitTranscriber.promptTokens(from: ["foo"], tokenizer: tokenizer)
        XCTAssertEqual(tokens, [5, 42, 7], "id >= specialTokenBegin 的特殊 token 必须被过滤")
    }

    func testPromptTokensCapsToLastMaxTokens() {
        // Encoding produces 0..<300; with a cap of 200 we keep the LAST 200 (the highest-priority suffix), i.e. 100..<300.
        let tokenizer = StubTokenizer(specialTokenBegin: 100_000, encoder: { _ in Array(0..<300) })
        let tokens = WhisperKitTranscriber.promptTokens(from: ["anything"], tokenizer: tokenizer, maxTokens: 200)
        XCTAssertEqual(tokens.count, 200)
        XCTAssertEqual(tokens.first, 100, "超过上限时应保留后缀（最相关在尾部），首元素应是被裁掉前缀后的第 100 个")
        XCTAssertEqual(tokens.last, 299)
    }

    func testPromptTokensUnderCapKeepsAll() {
        let tokenizer = StubTokenizer(specialTokenBegin: 100_000, encoder: { _ in [1, 2, 3] })
        let tokens = WhisperKitTranscriber.promptTokens(from: ["term"], tokenizer: tokenizer, maxTokens: 200)
        XCTAssertEqual(tokens, [1, 2, 3], "未超过上限时应保留全部 token")
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
