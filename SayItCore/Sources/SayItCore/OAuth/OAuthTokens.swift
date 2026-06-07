import Foundation

public struct OAuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String
    public let accountId: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, idToken: String,
                accountId: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.expiresAt = expiresAt
    }

    /// The lead time (seconds) for the expiry decision: treated as expired this many seconds before the real expiry, to avoid 401s on boundary requests.
    /// Note it must be far smaller than ChatGPTOAuth.defaultExpiresIn, otherwise a token with the default validity would be immediately judged expired.
    public static let expiryLeeway: TimeInterval = 60

    /// Treated as expired expiryLeeway seconds early, to avoid 401s on boundary requests.
    public func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-Self.expiryLeeway)
    }
}
