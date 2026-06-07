import Foundation

/// ChatGPT(Codex) OAuth: builds the authorization URL, exchange/refresh token requests, parses tokens, extracts account_id from the JWT.
/// The protocol constants come from the openai/codex and OpenClaw source (originator=openclaw).
public enum ChatGPTOAuth {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeEndpoint = "https://auth.openai.com/oauth/authorize"
    public static let tokenEndpoint = "https://auth.openai.com/oauth/token"
    /// The Codex Responses API (SSE) endpoint (single source of truth, reused by CodexResponsesProvider).
    public static let responsesEndpoint = "https://chatgpt.com/backend-api/codex/responses"
    /// The port/host of the OAuth callback local loopback service (single source of truth, reused by CodexLoginService to start NWListener and assemble the callback URL).
    public static let callbackHost = "127.0.0.1"
    public static let callbackPort: UInt16 = 1455
    /// The redirect_uri registered with the authorization server (the value is fixed to http://localhost:1455/auth/callback, the port reuses callbackPort).
    public static let redirectURI = "http://localhost:\(callbackPort)/auth/callback"
    public static let scope = "openid profile email offline_access"
    /// The protocol originator (single source of truth, reused to derive the authorization URL, Responses header, User-Agent).
    public static let originator = "openclaw"
    /// The OS segment of the User-Agent (appended after originator): the final UA = originator + this segment.
    public static let userAgentOSSegment = " (macOS)"
    /// The default User-Agent (originator + OS segment, single source of truth): the value is byte-for-byte identical to the original inline "\(originator) (macOS)".
    public static let defaultUserAgent = originator + userAgentOSSegment
    /// The fallback validity period (seconds) when the token response omits expires_in.
    /// Note it must be far larger than OAuthTokens.expiryLeeway, otherwise a freshly obtained token would be immediately judged expired.
    public static let defaultExpiresIn: Double = 3600

    public static func authorizeURL(pkce: PKCE, state: String) -> URL {
        var c = URLComponents(string: authorizeEndpoint)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: originator),
        ]
        return c.url!
    }

    public static func tokenExchangeRequest(code: String, verifier: String) -> URLRequest {
        formPost(body: "grant_type=authorization_code&code=\(enc(code))"
            + "&redirect_uri=\(enc(redirectURI))&client_id=\(enc(clientID))&code_verifier=\(enc(verifier))")
    }

    public static func refreshRequest(refreshToken: String) -> URLRequest {
        formPost(body: "grant_type=refresh_token&refresh_token=\(enc(refreshToken))&client_id=\(enc(clientID))")
    }

    /// Parses the token response into OAuthTokens. The refresh response may not return a refresh_token, so use the fallback.
    public static func parseTokenResponse(_ data: Data, fallbackRefresh: String = "") throws -> OAuthTokens {
        struct Resp: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let expires_in: Double?
        }
        let r: Resp
        do {
            r = try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            // The token response (under a success status code) failed to decode: only log the error type and localized description, never print the response body (avoiding token leaks); behavior unchanged, still throws .invalidResponse.
            NSLog("[SayIt][ChatGPTOAuth] token 响应解码失败 type=%@ desc=%@",
                  String(describing: type(of: error)), error.localizedDescription)
            throw ProviderError.invalidResponse
        }
        let accountId = accountID(fromJWT: r.access_token) ?? accountID(fromJWT: r.id_token ?? "") ?? ""
        return OAuthTokens(
            accessToken: r.access_token,
            refreshToken: r.refresh_token ?? fallbackRefresh,
            idToken: r.id_token ?? "",
            accountId: accountId,
            expiresAt: Date().addingTimeInterval(r.expires_in ?? defaultExpiresIn))
    }

    /// The part of the JWT payload we care about: ["https://api.openai.com/auth"]["chatgpt_account_id"].
    /// Explicitly modeled with Decodable, to avoid silently degrading to empty when reading values from [String:Any].
    private struct JWTPayload: Decodable {
        struct Auth: Decodable {
            let chatgpt_account_id: String?
        }
        let auth: Auth?
        private enum CodingKeys: String, CodingKey {
            case auth = "https://api.openai.com/auth"
        }
    }

    /// Decodes the JWT payload and extracts ["https://api.openai.com/auth"]["chatgpt_account_id"].
    public static func accountID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let payload = try? JSONDecoder().decode(JWTPayload.self, from: data) else { return nil }
        return payload.auth?.chatgpt_account_id
    }

    private static func formPost(body: String) -> URLRequest {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: HTTPConstants.contentTypeHeader)
        req.httpBody = Data(body.utf8)
        return req
    }

    private static func enc(_ s: String) -> String {
        // RFC 3986 unreserved characters (including _ - . ~) are not encoded, the rest are encoded;
        // this guarantees the underscore in client_id stays as-is in the form body.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
