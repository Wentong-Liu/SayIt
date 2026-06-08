import XCTest
@testable import SayItCore

/// CodexResponsesProvider unit test: uses a URLProtocol stub to intercept the Responses request,
/// asserting the request body now carries reasoning.effort == "minimal" (the speed fix) while every
/// other field stays byte-identical (model/store/stream/instructions/input/text.verbosity/include/
/// tool_choice/parallel_tool_calls). A minimal SSE success response drives complete() to completion.
///
/// RequestBody/ReasoningOption are private, so the test asserts on the captured raw httpBody JSON --
/// the intended, robust contract test. No real network throughout.
final class CodexResponsesProviderTests: XCTestCase {

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

    /// A minimal valid SSE success response: an output_text.delta of "ok" followed by response.completed,
    /// so readStream returns "ok". AsyncBytes.lines iterates the full Data, so no streaming machinery is needed.
    private static func sseSuccess() -> (HTTPURLResponse, Data) {
        let resp = HTTPURLResponse(url: URL(string: ChatGPTOAuth.responsesEndpoint)!,
                                   statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "text/event-stream"])!
        let body = Data((
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n" +
            "data: {\"type\":\"response.completed\"}\n\n"
        ).utf8)
        return (resp, body)
    }

    /// Drives complete() through the stub, returning the parsed text and the captured request body JSON.
    private func runAndCaptureBody() async throws -> (output: String, json: [String: Any]) {
        final class Box: @unchecked Sendable { var body: Data? }
        let box = Box()
        StubURLProtocol.responder = { req in
            box.body = req.httpBody ?? StubURLProtocol.bodyData(from: req)
            return Self.sseSuccess()
        }
        let provider = CodexResponsesProvider(accessToken: "tok", accountId: "acct",
                                              model: "gpt-5.5", session: stubbedSession())
        let out = try await provider.complete(messages: [
            .init(role: .system, content: "sys"),
            .init(role: .user, content: "hi"),
        ])
        let data = try XCTUnwrap(box.body, "request body was not captured")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                 "request body was not a JSON object")
        return (out, json)
    }

    /// The new behavior: the Responses request body carries reasoning.effort == "minimal".
    func testRequestBodyIncludesMinimalReasoningEffort() async throws {
        let (out, json) = try await runAndCaptureBody()
        XCTAssertEqual(out, "ok")
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any], "missing reasoning field")
        XCTAssertEqual(reasoning["effort"] as? String, "minimal")
    }

    /// Regression guards: every other field stays byte-identical to the pre-fix body.
    func testRequestBodyKeepsAllOtherFieldsUnchanged() async throws {
        let (_, json) = try await runAndCaptureBody()

        let text = try XCTUnwrap(json["text"] as? [String: Any], "missing text field")
        XCTAssertEqual(text["verbosity"] as? String, "low")

        XCTAssertEqual(json["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["tool_choice"] as? String, "auto")
        XCTAssertEqual(json["parallel_tool_calls"] as? Bool, true)
        XCTAssertEqual(json["model"] as? String, "gpt-5.5")
        XCTAssertEqual(json["instructions"] as? String, "sys")

        let input = try XCTUnwrap(json["input"] as? [[String: Any]], "missing input array")
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["role"] as? String, "user")
    }

    // MARK: - Failure paths (behavior preserved alongside the new diagnostic logging)

    /// A non-2xx status still maps to `ProviderError.httpError` carrying the status + body, unchanged by the added
    /// `.error` logging. (The diagnostic log line itself is a side effect and is read out-of-band via `log stream`.)
    func testNon2xxStatusStillThrowsHTTPErrorWithStatusAndBody() async {
        StubURLProtocol.responder = { _ in
            let resp = HTTPURLResponse(url: URL(string: ChatGPTOAuth.responsesEndpoint)!,
                                       statusCode: 400, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            let body = Data(#"{"error":{"message":"Unsupported value: 'reasoning.effort'"}}"#.utf8)
            return (resp, body)
        }
        let provider = CodexResponsesProvider(accessToken: "tok", accountId: "acct",
                                              model: "gpt-5.5", session: stubbedSession())
        do {
            _ = try await provider.complete(messages: [.init(role: .user, content: "hi")])
            XCTFail("a non-2xx status should throw ProviderError.httpError")
        } catch let ProviderError.httpError(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("reasoning.effort"), "the error body should be preserved, actual: \(body)")
        } catch {
            XCTFail("expected ProviderError.httpError, actual: \(error)")
        }
    }

    /// An SSE `error` event still maps to `ProviderError.streamFailed` carrying the payload, unchanged by the added logging.
    func testStreamErrorEventStillThrowsStreamFailed() async {
        StubURLProtocol.responder = { _ in
            let resp = HTTPURLResponse(url: URL(string: ChatGPTOAuth.responsesEndpoint)!,
                                       statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
            let body = Data("data: {\"type\":\"error\",\"message\":\"upstream boom\"}\n\n".utf8)
            return (resp, body)
        }
        let provider = CodexResponsesProvider(accessToken: "tok", accountId: "acct",
                                              model: "gpt-5.5", session: stubbedSession())
        do {
            _ = try await provider.complete(messages: [.init(role: .user, content: "hi")])
            XCTFail("an SSE error event should throw ProviderError.streamFailed")
        } catch let ProviderError.streamFailed(body) {
            XCTAssertTrue(body.contains("upstream boom"), "the error payload should be preserved, actual: \(body)")
        } catch {
            XCTFail("expected ProviderError.streamFailed, actual: \(error)")
        }
    }
}
