import WhisperKit
import XCTest
@testable import SayItCore

/// 不依赖模型下载/加载的轻量单测：覆盖初始化、输入守卫、纯映射逻辑。
/// 真实转写（需联网拉模型 + Core ML 推理）留到集成阶段在真机验证。
final class WhisperKitTranscriberTests: XCTestCase {
    // MARK: - 初始化

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

    // MARK: - 输入守卫（在加载模型之前即返回，不触发任何下载）

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

    // MARK: - 纯映射逻辑 mapResult

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
        // 分块拼接（各段自带首尾空格、以 " " 连接）会产出双空格；mapResult 应折叠为单空格。
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

    // MARK: - DecodingOptions 构造（语言自动检测回归保护）

    // 回归：用户说中文却被转写/翻译成英文。根因是 language==nil 且 detectLanguage 关闭时，
    // WhisperKit 在 TranscribeTask 里跳过语言检测，回落到 Constants.defaultLanguageCode（"en"），
    // 于是按英文解码。下面的用例锁定「nil 语言 => 自动检测」与「task 永远是 transcribe（绝不 translate）」。

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

    // MARK: - 协议一致性

    func testUsableThroughTranscriberExistential() {
        let _: any Transcriber = WhisperKitTranscriber()
    }
}
