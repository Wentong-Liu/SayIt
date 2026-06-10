import Foundation

/// HTTP response validation shared by the two providers: extracts "get HTTPURLResponse + status-code range check + map to ProviderError"
/// into one place, guaranteeing both sides behave identically.
public enum HTTPResponseValidator {
    /// Status-code range treated as success.
    public static let successRange = 200..<300

    /// Casts URLResponse to HTTPURLResponse; throws `.invalidResponse` if it is not an HTTP response.
    static func httpResponse(from response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return http
    }

    /// Any non-2xx status code throws `.httpError(status:body:)`, otherwise returns normally.
    /// `body` is supplied by the caller from its own data source (already-read Data / remaining streamed lines).
    static func throwIfHTTPError(_ http: HTTPURLResponse, body: @autoclosure () -> String) throws {
        guard successRange.contains(http.statusCode) else {
            throw ProviderError.httpError(status: http.statusCode, body: body())
        }
    }

    /// The body fragment logged when a 2xx response cannot be JSON-decoded: the UTF-8 text (or "" if not UTF-8),
    /// truncated to the first 500 characters. Pure (no side effect) so the truncation/fallback is unit-testable.
    static func decodeFailureSnippet(data: Data) -> String {
        String((String(data: data, encoding: .utf8) ?? "").prefix(500))
    }

    /// Logs the shared "HTTP 2xx but JSON decode failed" diagnostic for a provider, identified by `tag`
    /// (`Anthropic` / `OpenAICompatible`). Emits the exact same line both providers logged inline before — the
    /// only per-provider difference is the bracketed tag, interpolated into the literal so the positional
    /// `%d`/`%@` mapping (statusCode, snippet) is preserved byte-for-byte.
    static func logDecodeFailure(tag: String, statusCode: Int, data: Data) {
        let snippet = decodeFailureSnippet(data: data)
        NSLog("[SayIt][\(tag)] HTTP %d 成功但 JSON 解码失败，body 片段=%@", statusCode, snippet)
    }
}
