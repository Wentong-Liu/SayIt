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

    // MARK: - Protocol conformance

    func testUsableThroughTranscriberExistential() {
        let _: any Transcriber = WhisperKitTranscriber()
    }
}
