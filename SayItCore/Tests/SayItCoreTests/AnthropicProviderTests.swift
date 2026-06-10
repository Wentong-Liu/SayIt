import XCTest
@testable import SayItCore

/// AnthropicProvider unit test: intercepts the /messages request via the shared `StubURLProtocol`
/// (defined in CloudTranscriberTests, same test target) and asserts the encoded request body.
///
/// Focus: the polish / learned-term-extraction request is deterministic cleanup (hard constraint #1 is
/// "整理不回答 / never change meaning"), so it must run with a LOW sampling temperature for faithful,
/// low-variance results — not the old 0.9 ("diverse conversational") value.
///
/// The provider's `RequestBody` is `private`, so the field is verified through the captured HTTP body
/// (the public init + URLSession stub is the clean seam), not by touching production visibility. No real network.
final class AnthropicProviderTests: XCTestCase {

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
        let temperature: Double
    }

    /// Drives one polish call through a stub that returns a minimal HTTP 200 /messages reply,
    /// and returns the captured outgoing request body.
    private func captureBody(config: ProviderConfig) async throws -> Data {
        let captured = CapturedBody()
        StubURLProtocol.responder = { req in
            captured.store(req)
            let body = "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}".data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        }
        let provider = AnthropicProvider(config: config, apiKey: "k", session: stubbedSession())
        _ = try await provider.complete(messages: [
            LLMMessage(role: .system, content: "system"),
            LLMMessage(role: .user, content: "please polish this")
        ])
        return try XCTUnwrap(captured.body, "request body should have been captured")
    }

    func testEncodesLowSamplingTemperature() async throws {
        let bodyData = try await captureBody(config: .anthropic(model: "claude-haiku-4-5"))
        let decoded = try JSONDecoder().decode(DecodedBody.self, from: bodyData)
        XCTAssertLessThanOrEqual(decoded.temperature, 0.2,
                                 "deterministic cleanup must run at a low temperature, not the old 0.9")
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
