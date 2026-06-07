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

    /// 过期判定的提前量（秒）：在真正过期前这么多秒就视为已过期，避免边界请求 401。
    /// 注意须远小于 ChatGPTOAuth.defaultExpiresIn，否则缺省有效期的 token 会立即被判过期。
    public static let expiryLeeway: TimeInterval = 60

    /// 提前 expiryLeeway 秒视为过期，避免边界请求 401。
    public func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-Self.expiryLeeway)
    }
}
