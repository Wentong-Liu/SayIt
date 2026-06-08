import XCTest
@testable import SayItCore

/// OpenAICompatibleProvider unit test: intercepts the /chat/completions request via the shared
/// `StubURLProtocol` (defined in CloudTranscriberTests, same test target) and asserts the encoded request body.
///
/// Focus: the BYO-key OpenAI polish request now asks for the model's lowest supported reasoning tier so trivial
/// text-cleanup runs with minimal latency, WITHOUT ever sending a value the API would reject:
///   - OpenAI + gpt-5.5      => reasoning_effort == "none"    (GPT-5.5 supports the no-reasoning tier)
///   - OpenAI + gpt-5.4-mini => reasoning_effort == "minimal" (GPT-5.4 era 400s on "none")
///   - OpenAI + gpt-5-mini   => reasoning_effort == "minimal" (same floor — exercises the helper's else branch)
///   - DeepSeek              => the key is OMITTED entirely    (its /chat/completions rejects the field; body unchanged)
///
/// The provider's `RequestBody` and the floor helper are `private`, so the field is verified through the captured
/// HTTP body (the public init + URLSession stub is the clean seam), not by touching production visibility.
///
/// No real network throughout.
final class OpenAICompatibleProviderTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A minimal mirror of the encoded request body, exposing only the field we assert.
    private struct DecodedBody: Decodable {
        let reasoning_effort: String?
    }

    /// Drives one polish call through a stub that returns a minimal HTTP 200 chat/completions reply,
    /// and returns the captured outgoing request body.
    private func captureBody(config: ProviderConfig) async throws -> Data {
        let captured = CapturedBody()
        StubURLProtocol.responder = { req in
            captured.store(req)
            let body = "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}".data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        }
        let provider = OpenAICompatibleProvider(config: config, apiKey: "k", session: stubbedSession())
        _ = try await provider.complete(messages: [
            LLMMessage(role: .system, content: "system"),
            LLMMessage(role: .user, content: "please polish this")
        ])
        return try XCTUnwrap(captured.body, "request body should have been captured")
    }

    func testOpenAIGPT55EncodesReasoningEffortNone() async throws {
        let bodyData = try await captureBody(config: .openAI(model: "gpt-5.5"))
        let decoded = try JSONDecoder().decode(DecodedBody.self, from: bodyData)
        XCTAssertEqual(decoded.reasoning_effort, "none",
                       "OpenAI + gpt-5.5 must request the no-reasoning \"none\" tier")
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("\"reasoning_effort\":\"none\""),
                      "the wire body should contain reasoning_effort=none; got: \(bodyString)")
    }

    func testOpenAIGPT54MiniEncodesReasoningEffortMinimal() async throws {
        let bodyData = try await captureBody(config: .openAI(model: "gpt-5.4-mini"))
        let decoded = try JSONDecoder().decode(DecodedBody.self, from: bodyData)
        XCTAssertEqual(decoded.reasoning_effort, "minimal",
                       "the default BYO model gpt-5.4-mini only goes down to \"minimal\" (it 400s on \"none\")")
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("\"reasoning_effort\":\"minimal\""),
                      "the wire body should contain reasoning_effort=minimal; got: \(bodyString)")
    }

    func testOpenAIGPT5MiniEncodesReasoningEffortMinimal() async throws {
        // Belt-and-suspenders on the floor mapping's else branch (exercised through the body, helper stays private).
        let bodyData = try await captureBody(config: .openAI(model: "gpt-5-mini"))
        let decoded = try JSONDecoder().decode(DecodedBody.self, from: bodyData)
        XCTAssertEqual(decoded.reasoning_effort, "minimal",
                       "gpt-5-mini only goes down to \"minimal\" (it 400s on \"none\")")
    }

    func testDeepSeekOmitsReasoningEffort() async throws {
        let bodyData = try await captureBody(config: .deepSeek(model: "deepseek-v4-flash"))
        let decoded = try JSONDecoder().decode(DecodedBody.self, from: bodyData)
        XCTAssertNil(decoded.reasoning_effort,
                     "DeepSeek's /chat/completions does not accept reasoning_effort")
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyString.contains("reasoning_effort"),
                       "the DeepSeek wire body must omit the reasoning_effort key entirely; got: \(bodyString)")
    }
}

/// Records the (possibly streamed) HTTP body of the intercepted request.
private final class CapturedBody: @unchecked Sendable {
    private let lock = NSLock()
    private var bodyData: Data?

    func store(_ req: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        bodyData = req.httpBody ?? StubURLProtocol.bodyData(from: req)
    }

    var body: Data? { lock.lock(); defer { lock.unlock() }; return bodyData }
}
