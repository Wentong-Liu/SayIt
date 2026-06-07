import Foundation

public enum ProviderError: Error, Equatable, Sendable {
    case missingAPIKey
    case httpError(status: Int, body: String)
    /// Streamed read failed: upstream returned an error/response.failed event, or the stream was judged stalled (timed out).
    case streamFailed(body: String)
    case invalidResponse
    case network(String)
}

extension ProviderError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingAPIKey:
            return "ProviderError.missingAPIKey"
        case let .httpError(status, body):
            return "ProviderError.httpError(status: \(status), body: \(body))"
        case let .streamFailed(body):
            return "ProviderError.streamFailed(body: \(body))"
        case .invalidResponse:
            return "ProviderError.invalidResponse"
        case let .network(message):
            return "ProviderError.network(\(message))"
        }
    }
}
