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
        StallingErrorBodyURLProtocol.reset()
        CodexResponsesProvider.maxErrorBodySeconds = 90
        super.tearDown()
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A session whose protocol returns a non-2xx response header and then half-opens/hangs the body forever.
    private func stallingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingErrorBodyURLProtocol.self]
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

    // MARK: - Non-2xx error-body read is bounded (does not hang on a half-open/stalled body)

    /// REGRESSION GUARD: a non-2xx server that half-opens and then hangs the body must NOT make `complete()` hang.
    /// Before the fix the error path drained `bytes.lines` with no timeout, so a stalled half-open body blocked the
    /// whole polish call forever (URLRequest.timeoutInterval is a per-chunk inactivity timer and never fires on a fully
    /// stalled body). With the bound, the error-body read gives up after `maxErrorBodySeconds` and `complete()` still
    /// surfaces the HTTP status (with whatever partial body it managed to read). We lower the cap to keep the test fast
    /// and wrap the call in our own watchdog so a true hang fails fast instead of stalling the whole suite.
    func testNon2xxWithStalledBodyDoesNotHangAndSurfacesStatus() async throws {
        CodexResponsesProvider.maxErrorBodySeconds = 1
        StallingErrorBodyURLProtocol.statusCode = 429
        // Emit one partial body line, then never finish -> a half-open, stalled body.
        StallingErrorBodyURLProtocol.partialBody = "data: {\"error\":\"rate limited\"}\n".data(using: .utf8)!

        let provider = CodexResponsesProvider(accessToken: "token-test",
                                              accountId: "acct-test",
                                              model: "gpt-5.5",
                                              session: stallingSession())

        // Watchdog: the call must complete (throw) well within this bound; a regression would hang far past it.
        // The result enum distinguishes "complete() threw a ProviderError" (the contract) from "the watchdog fired first"
        // (a hang regression). Both branches return a Result so neither racer leaks an error out of the group.
        enum Outcome: Sendable { case completed(ProviderError?); case watchdogFired }
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    _ = try await provider.complete(messages: [
                        LLMMessage(role: .system, content: "system"),
                        LLMMessage(role: .user, content: "please polish this")
                    ])
                    return .completed(nil)
                } catch let error as ProviderError {
                    return .completed(error)
                } catch {
                    return .completed(nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .watchdogFired
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        guard case let .completed(maybeError) = outcome else {
            return XCTFail("complete() did not return within the watchdog window -- the stalled error body hung the call")
        }
        let error = try XCTUnwrap(maybeError, "complete() must throw a ProviderError on a non-2xx response, not succeed")
        guard case let .httpError(status, _) = error else {
            return XCTFail("expected ProviderError.httpError, got \(error)")
        }
        XCTAssertEqual(status, 429, "the surfaced HTTP status must be preserved even when the error body stalls")
    }

    /// A non-2xx whose body DOES arrive (and closes) is still surfaced with both the status and the body text -- the
    /// bound must not truncate or drop an error body that completes promptly.
    func testNon2xxWithCompleteBodySurfacesStatusAndBody() async throws {
        StubURLProtocol.responder = { req in
            let body = "data: {\"error\":\"bad effort\"}".data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
            return (resp, body)
        }
        let provider = CodexResponsesProvider(accessToken: "token-test",
                                              accountId: "acct-test",
                                              model: "gpt-5.5",
                                              session: stubbedSession())
        do {
            _ = try await provider.complete(messages: [
                LLMMessage(role: .system, content: "system"),
                LLMMessage(role: .user, content: "please polish this")
            ])
            XCTFail("expected ProviderError.httpError to be thrown")
        } catch let error as ProviderError {
            guard case let .httpError(status, body) = error else {
                return XCTFail("expected ProviderError.httpError, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("bad effort"), "a promptly-delivered error body must still be surfaced: \(body)")
        }
    }
}

/// URLProtocol stub that returns a non-2xx response header, emits an optional partial body chunk, then HANGS the body
/// forever (never calls `urlProtocolDidFinishLoading`). This reproduces a server that half-opens the connection and
/// stalls the error body -- the case the bounded error-body read must survive without hanging the whole polish call.
/// On cancellation (`stopLoading`, triggered when the provider's timeout race cancels the read) it simply stops.
final class StallingErrorBodyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 429
    nonisolated(unsafe) static var partialBody: Data?

    static func reset() {
        statusCode = 429
        partialBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil,
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if let partial = Self.partialBody {
            client?.urlProtocol(self, didLoad: partial)
        }
        // Intentionally never finish: leave the body half-open so the reader stalls waiting for the next line / EOF.
    }

    override func stopLoading() {}
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
