import XCTest
@testable import SayItCore

/// CloudTranscriber unit test: uses a URLProtocol stub to intercept all requests, asserting
/// - the shape of the uploaded multipart body (including WAV header correctness, file/model fields)
/// - the URL / method / Authorization header
/// - a successful response parsed into TranscriptionResult
/// - various errors (empty audio / non-HTTP / non-2xx / parse failure / network) mapped to STTError
///
/// No real network throughout.
final class CloudTranscriberTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// Builds an isolated URLSession that hands requests to StubURLProtocol.
    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTranscriber(baseURL: String = "https://api.openai.com",
                                 apiKey: String = "sk-test",
                                 model: String = "gpt-4o-mini-transcribe") -> CloudTranscriber {
        CloudTranscriber(baseURL: baseURL, apiKey: apiKey, model: model, session: stubbedSession())
    }

    // MARK: - Success path / response parsing

    func testSuccessfulResponseParsesText() async throws {
        StubURLProtocol.responder = { _ in
            let body = #"{"text":"hello world"}"#.data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber()
        let result = try await transcriber.transcribe([0.1, -0.1, 0.2], sampleRate: 16_000, language: nil)
        XCTAssertEqual(result.text, "hello world")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNil(result.duration)
    }

    func testResponseWithExtraFieldsStillParses() async throws {
        StubURLProtocol.responder = { _ in
            let body = #"{"task":"transcribe","language":"en","duration":1.5,"text":"keep this"}"#.data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber()
        let result = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: "en")
        XCTAssertEqual(result.text, "keep this")
    }

    // MARK: - URL / method / auth header

    func testRequestTargetsTranscriptionsEndpoint() async throws {
        let captured = Captured()
        StubURLProtocol.responder = { req in
            captured.store(req)
            let body = #"{"text":"x"}"#.data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber(baseURL: "https://api.openai.com", apiKey: "sk-secret")
        _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)

        XCTAssertEqual(captured.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.header("Authorization"), "Bearer sk-secret")
    }

    func testBaseURLTrailingSlashIsNormalized() async throws {
        let captured = Captured()
        StubURLProtocol.responder = { req in
            captured.store(req)
            let body = #"{"text":"x"}"#.data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber(baseURL: "https://example.com/")
        _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        XCTAssertEqual(captured.url?.absoluteString, "https://example.com/v1/audio/transcriptions")
    }

    func testCustomBaseURLForCompatibleProvider() async throws {
        let captured = Captured()
        StubURLProtocol.responder = { req in
            captured.store(req)
            let body = #"{"text":"x"}"#.data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber(baseURL: "https://my-proxy.example/openai")
        _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        XCTAssertEqual(captured.url?.absoluteString, "https://my-proxy.example/openai/v1/audio/transcriptions")
    }

    // MARK: - multipart body construction

    func testMultipartBodyContainsModelAndFileFields() async throws {
        let captured = Captured()
        StubURLProtocol.responder = { req in
            captured.store(req)
            let body = #"{"text":"x"}"#.data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber(model: "whisper-1")
        _ = try await transcriber.transcribe([0.1, 0.2], sampleRate: 16_000, language: nil)

        // Content-Type must be multipart/form-data with a boundary.
        let contentType = captured.header("Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), "got: \(contentType)")
        let boundary = String(contentType.split(separator: "=", maxSplits: 1).last ?? "")
        XCTAssertFalse(boundary.isEmpty)

        let bodyData = captured.body ?? Data()
        // The model field and its value must appear.
        XCTAssertNotNil(captured.bodyString.range(of: "name=\"model\""))
        XCTAssertNotNil(captured.bodyString.range(of: "whisper-1"))
        // The file field, file name and audio content-type must appear.
        XCTAssertNotNil(captured.bodyString.range(of: "name=\"file\""))
        XCTAssertNotNil(captured.bodyString.range(of: "filename=\"audio.wav\""))
        XCTAssertNotNil(captured.bodyString.range(of: "Content-Type: audio/wav"))
        // The body must actually contain the WAV RIFF/WAVE identifier bytes.
        XCTAssertTrue(bodyData.containsSubsequence(Array("RIFF".utf8)))
        XCTAssertTrue(bodyData.containsSubsequence(Array("WAVE".utf8)))
        // The body must end with the closing boundary.
        XCTAssertTrue(captured.bodyString.contains("--\(boundary)--"))
    }

    func testLanguageFieldSentWhenProvided() async throws {
        let captured = Captured()
        StubURLProtocol.responder = { req in
            captured.store(req)
            let body = #"{"text":"x"}"#.data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber()
        _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: "zh")
        XCTAssertNotNil(captured.bodyString.range(of: "name=\"language\""))
        XCTAssertNotNil(captured.bodyString.range(of: "zh"))
    }

    func testLanguageFieldOmittedWhenNil() async throws {
        let captured = Captured()
        StubURLProtocol.responder = { req in
            captured.store(req)
            let body = #"{"text":"x"}"#.data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber()
        _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        XCTAssertNil(captured.bodyString.range(of: "name=\"language\""))
    }

    // MARK: - WAV header correctness

    func testEncodedWAVHeaderIsValid() throws {
        // 3 samples @16kHz, mono, 16-bit.
        let samples: [Float] = [0.0, 1.0, -1.0]
        let wav = try WAVEncoder.encode(samples: samples, sampleRate: 16_000)

        // The header is at least 44 bytes.
        XCTAssertGreaterThanOrEqual(wav.count, 44)
        let bytes = [UInt8](wav)

        // RIFF chunk descriptor
        XCTAssertEqual(Array(bytes[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(Array(bytes[8..<12]), Array("WAVE".utf8))
        // ChunkSize = 36 + dataSize
        let dataSize = samples.count * 2
        XCTAssertEqual(le32(bytes, 4), UInt32(36 + dataSize))

        // fmt subchunk
        XCTAssertEqual(Array(bytes[12..<16]), Array("fmt ".utf8))
        XCTAssertEqual(le32(bytes, 16), 16)          // Subchunk1Size for PCM
        XCTAssertEqual(le16(bytes, 20), 1)           // AudioFormat = PCM
        XCTAssertEqual(le16(bytes, 22), 1)           // NumChannels = 1
        XCTAssertEqual(le32(bytes, 24), 16_000)      // SampleRate
        XCTAssertEqual(le32(bytes, 28), 16_000 * 2)  // ByteRate = sampleRate * channels * bytesPerSample
        XCTAssertEqual(le16(bytes, 32), 2)           // BlockAlign = channels * bytesPerSample
        XCTAssertEqual(le16(bytes, 34), 16)          // BitsPerSample

        // data subchunk
        XCTAssertEqual(Array(bytes[36..<40]), Array("data".utf8))
        XCTAssertEqual(le32(bytes, 40), UInt32(dataSize))
        XCTAssertEqual(wav.count, 44 + dataSize)
    }

    func testWAVSampleClampingAndScaling() throws {
        // 1.0 -> Int16.max ; -1.0 -> Int16.min ; 0 -> 0 ; out-of-range values clamped.
        let samples: [Float] = [0.0, 1.0, -1.0, 2.0, -2.0]
        let wav = try WAVEncoder.encode(samples: samples, sampleRate: 16_000)
        let bytes = [UInt8](wav)
        XCTAssertEqual(s16(bytes, 44), 0)
        XCTAssertEqual(s16(bytes, 46), Int16.max)
        XCTAssertEqual(s16(bytes, 48), Int16.min)
        XCTAssertEqual(s16(bytes, 50), Int16.max)  // 2.0 clamped
        XCTAssertEqual(s16(bytes, 52), Int16.min)  // -2.0 clamped
    }

    func testWAVUsesProvidedSampleRate() throws {
        let wav = try WAVEncoder.encode(samples: [0.0], sampleRate: 8_000)
        let bytes = [UInt8](wav)
        XCTAssertEqual(le32(bytes, 24), 8_000)
        XCTAssertEqual(le32(bytes, 28), 8_000 * 2)
    }

    // MARK: - Error mapping

    func testEmptyAudioThrowsBeforeNetwork() async {
        StubURLProtocol.responder = { _ in
            XCTFail("network must not be hit for empty audio")
            let body = Data()
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber()
        await assertThrows(STTError.emptyAudio) {
            _ = try await transcriber.transcribe([], sampleRate: 16_000, language: nil)
        }
    }

    func testMissingAPIKeyThrowsNotReady() async {
        StubURLProtocol.responder = { _ in
            XCTFail("network must not be hit when key missing")
            let body = Data()
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber(apiKey: "")
        await assertThrows(STTError.notReady) {
            _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        }
    }

    func testInvalidSampleRateThrowsUnsupportedFormatBeforeNetwork() async {
        StubURLProtocol.responder = { _ in
            XCTFail("network must not be hit for invalid sample rate")
            let body = Data()
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber()
        await assertThrows(STTError.unsupportedFormat) {
            _ = try await transcriber.transcribe([0.1], sampleRate: 0, language: nil)
        }
    }

    func testHTTPErrorMapsToTranscriptionFailed() async {
        StubURLProtocol.responder = { _ in
            let body = #"{"error":{"message":"bad key"}}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                                       statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let transcriber = makeTranscriber()
        do {
            _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
            XCTFail("expected STTError to be thrown")
        } catch let error as STTError {
            guard case let .transcriptionFailed(reason) = error else {
                return XCTFail("expected .transcriptionFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("401"), "reason should carry status: \(reason)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testNonHTTPResponseMapsToTranscriptionFailed() async {
        // Returns a non-HTTPURLResponse.
        StubURLProtocol.responder = { req in
            let resp = URLResponse(url: req.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            return (resp, Data())
        }
        let transcriber = makeTranscriber()
        await assertThrowsTranscriptionFailed {
            _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        }
    }

    func testMalformedJSONMapsToTranscriptionFailed() async {
        StubURLProtocol.responder = { _ in
            let body = "not json at all".data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber()
        await assertThrowsTranscriptionFailed {
            _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        }
    }

    func testJSONMissingTextFieldMapsToTranscriptionFailed() async {
        StubURLProtocol.responder = { _ in
            let body = #"{"language":"en"}"#.data(using: .utf8)!
            return (Self.ok(body), body)
        }
        let transcriber = makeTranscriber()
        await assertThrowsTranscriptionFailed {
            _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        }
    }

    func testNetworkErrorMapsToTranscriptionFailed() async {
        StubURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        let transcriber = makeTranscriber()
        await assertThrowsTranscriptionFailed {
            _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        }
    }

    // MARK: - Helpers

    private static func ok(_ body: Data) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                        statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!
    }

    private func assertThrows(_ expected: STTError,
                              _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected) to be thrown", file: file, line: line)
        } catch let error as STTError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    private func assertThrowsTranscriptionFailed(_ body: () async throws -> Void,
                                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected STTError.transcriptionFailed", file: file, line: line)
        } catch let error as STTError {
            guard case .transcriptionFailed = error else {
                return XCTFail("expected .transcriptionFailed, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    // little-endian readers for header assertions
    private func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
    private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private func s16(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: le16(b, i))
    }
}

// MARK: - Test helper types

/// Records a snapshot of the intercepted request (thread-safe enough: the test consumes single-threaded).
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var bodyData: Data?

    func store(_ req: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        request = req
        // Under URLProtocol httpBody usually exists; if a stream is used, read it out.
        bodyData = req.httpBody ?? StubURLProtocol.bodyData(from: req)
    }

    var url: URL? { lock.lock(); defer { lock.unlock() }; return request?.url }
    var method: String? { lock.lock(); defer { lock.unlock() }; return request?.httpMethod }
    var body: Data? { lock.lock(); defer { lock.unlock() }; return bodyData }
    var bodyString: String {
        lock.lock(); defer { lock.unlock() }
        guard let d = bodyData else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    func header(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return request?.value(forHTTPHeaderField: name)
    }
}

/// URLProtocol stub: intercepts all requests, returning the responder's given (response, data) or throwing errorToThrow.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (URLResponse, Data))?
    nonisolated(unsafe) static var errorToThrow: Error?

    static func reset() {
        responder = nil
        errorToThrow = nil
    }

    /// Reads the body bytes from a possibly-stream request (URLSession often uses httpBodyStream when uploading multipart).
    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.errorToThrow {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    /// A naive subsequence containment check, used to assert the body contains byte sequences such as "RIFF"/"WAVE".
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        let hay = [UInt8](self)
        let upper = hay.count - needle.count
        var i = 0
        while i <= upper {
            if Array(hay[i..<(i + needle.count)]) == needle { return true }
            i += 1
        }
        return false
    }
}
