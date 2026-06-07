import XCTest
@testable import SayItCore

final class TranscriberTests: XCTestCase {
    // MARK: - TranscriptionResult

    func testTranscriptionResultStoresText() {
        let result = TranscriptionResult(text: "hello world")
        XCTAssertEqual(result.text, "hello world")
        XCTAssertNil(result.duration)
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testTranscriptionResultStoresSegmentsAndDuration() {
        let segments = [
            TranscriptionResult.Segment(text: "hello", start: 0, end: 1.2),
            TranscriptionResult.Segment(text: "world", start: 1.2, end: 2.4),
        ]
        let result = TranscriptionResult(text: "hello world", segments: segments, duration: 2.4)
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.duration, 2.4)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "hello")
        XCTAssertEqual(result.segments[1].start, 1.2)
        XCTAssertEqual(result.segments[1].end, 2.4)
    }

    func testTranscriptionResultIsEquatable() {
        let a = TranscriptionResult(text: "same", duration: 1)
        let b = TranscriptionResult(text: "same", duration: 1)
        XCTAssertEqual(a, b)
    }

    // MARK: - FakeTranscriber: success path

    func testFakeReturnsPresetText() async throws {
        let fake = FakeTranscriber(result: TranscriptionResult(text: "preset"))
        let out = try await fake.transcribe([0.0, 0.1], sampleRate: 16_000, language: nil)
        XCTAssertEqual(out.text, "preset")
    }

    func testFakeConvenienceTextInitializer() async throws {
        let fake = FakeTranscriber(text: "quick")
        let out = try await fake.transcribe([], sampleRate: 16_000, language: "en")
        XCTAssertEqual(out.text, "quick")
    }

    func testFakeRecordsLastCallArguments() async throws {
        let fake = FakeTranscriber(text: "ok")
        let audio: [Float] = [0.1, 0.2, 0.3]
        _ = try await fake.transcribe(audio, sampleRate: 44_100, language: "zh")

        let calls = await fake.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].audio, audio)
        XCTAssertEqual(calls[0].sampleRate, 44_100)
        XCTAssertEqual(calls[0].language, "zh")
    }

    func testFakeRecordsMultipleCalls() async throws {
        let fake = FakeTranscriber(text: "ok")
        _ = try await fake.transcribe([0.1], sampleRate: 16_000, language: nil)
        _ = try await fake.transcribe([0.2], sampleRate: 16_000, language: "en")
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(calls[0].language)
        XCTAssertEqual(calls[1].language, "en")
    }

    // MARK: - FakeTranscriber: error path

    func testFakeThrowsConfiguredError() async {
        let fake = FakeTranscriber(error: STTError.notReady)
        do {
            _ = try await fake.transcribe([0.0], sampleRate: 16_000, language: nil)
            XCTFail("expected STTError.notReady to be thrown")
        } catch let error as STTError {
            XCTAssertEqual(error, STTError.notReady)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFakeThrowsEmptyAudioError() async {
        let fake = FakeTranscriber(error: STTError.emptyAudio)
        do {
            _ = try await fake.transcribe([], sampleRate: 16_000, language: nil)
            XCTFail("expected STTError.emptyAudio to be thrown")
        } catch let error as STTError {
            XCTAssertEqual(error, STTError.emptyAudio)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFakeStillRecordsCallWhenThrowing() async {
        let fake = FakeTranscriber(error: STTError.notReady)
        _ = try? await fake.transcribe([0.5], sampleRate: 8_000, language: "fr")
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].sampleRate, 8_000)
        XCTAssertEqual(calls[0].language, "fr")
    }

    // MARK: - Protocol usage through existential

    func testTranscriberUsableThroughExistential() async throws {
        let transcriber: any Transcriber = FakeTranscriber(text: "via protocol")
        let out = try await transcriber.transcribe([0.0], sampleRate: 16_000, language: nil)
        XCTAssertEqual(out.text, "via protocol")
    }

    // MARK: - STTError

    func testSTTErrorIsEquatable() {
        XCTAssertEqual(STTError.notReady, STTError.notReady)
        XCTAssertNotEqual(STTError.notReady, STTError.emptyAudio)
        XCTAssertEqual(
            STTError.transcriptionFailed(reason: "boom"),
            STTError.transcriptionFailed(reason: "boom")
        )
        XCTAssertNotEqual(
            STTError.transcriptionFailed(reason: "a"),
            STTError.transcriptionFailed(reason: "b")
        )
    }
}
