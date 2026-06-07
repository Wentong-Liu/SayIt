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
}
