import Foundation

/// Single source of truth for HTTP literals shared by all Providers (header names/values, path suffixes).
/// Consolidates inline strings scattered across Providers to avoid case/spelling drift.
enum HTTPConstants {
    // MARK: - Header names (canonical casing per the HTTP spec; header names themselves are case-insensitive)
    static let contentTypeHeader = "Content-Type"
    static let acceptHeader = "Accept"
    static let authorizationHeader = "Authorization"

    // MARK: - Header values
    static let applicationJSON = "application/json"

    // MARK: - Path suffixes
    /// Completion endpoint suffix for the OpenAI-compatible protocol (appended after baseURL).
    static let chatCompletionsPath = "/chat/completions"
    /// Endpoint suffix for the Anthropic Messages API (appended after baseURL).
    static let messagesPath = "/messages"
}

extension URLRequest {
    /// Writes `Authorization: Bearer <token>`. All Providers go through here to avoid duplicating the prefix.
    mutating func setBearerAuthorization(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: HTTPConstants.authorizationHeader)
    }
}
