import XCTest
@testable import SayItCore

/// CodexResponsesProvider unit test: intercepts the Responses (codex/responses) request via the shared
/// `StubURLProtocol` (defined in CloudTranscriberTests, same test target) and asserts the encoded request body.
///
/// Focus: the polish request now turns reasoning fully OFF -- the body must encode `reasoning.effort == "none"`.
/// The provider's `RequestBody` is `private`, so the field is verified through the captured HTTP body, not the type.
/// Light secondary asserts (text.verbosity == "low", store == false) prove the other fields stayed unchanged.
///
/// No real network throughout.
final class CodexResponsesProviderTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A minimal mirror of the encoded request body, exposing only the fields we assert.
    private struct DecodedBody: Decodable {
        struct Reasoning: Decodable { let effort: String }
        struct Text: Decodable { let verbosity: String }
        let reasoning: Reasoning
        let text: Text
        let store: Bool
    }

    func testRequestBodyEncodesReasoningEffortNone() async throws {
        let captured = CapturedBody()
        StubURLProtocol.responder = { req in
            captured.store(req)
            // A minimal terminal SSE event so the stream completes immediately with 200.
            let body = "data: {\"type\":\"response.completed\"}\n\n".data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
            return (resp, body)
        }

        let provider = CodexResponsesProvider(accessToken: "token-test",
                                              accountId: "acct-test",
                                              model: "gpt-5.5",
                                              session: stubbedSession())
        _ = try await provider.complete(messages: [
            LLMMessage(role: .system, content: "system"),
            LLMMessage(role: .user, content: "please polish this")
        ])

        let bodyData = try XCTUnwrap(captured.body, "request body should have been captured")
        let decoded = try JSONDecoder().decode(DecodedBody.self, from: bodyData)

        // CHANGE 1: reasoning fully off.
        XCTAssertEqual(decoded.reasoning.effort, "none",
                       "the Codex Responses request must encode reasoning.effort == \"none\"")
        // Other fields unchanged.
        XCTAssertEqual(decoded.text.verbosity, "low", "text.verbosity must stay \"low\"")
        XCTAssertFalse(decoded.store, "store must stay false")
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
