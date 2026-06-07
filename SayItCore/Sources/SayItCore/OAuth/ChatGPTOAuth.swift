import Foundation

/// ChatGPT(Codex) OAuth：构造授权 URL、换/刷 token 请求、解析 token、从 JWT 取 account_id。
/// 协议常量来自 openai/codex 与 OpenClaw 源码（originator=openclaw）。
public enum ChatGPTOAuth {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeEndpoint = "https://auth.openai.com/oauth/authorize"
    public static let tokenEndpoint = "https://auth.openai.com/oauth/token"
    /// Codex Responses API（SSE）端点（单一真相源，供 CodexResponsesProvider 复用）。
    public static let responsesEndpoint = "https://chatgpt.com/backend-api/codex/responses"
    /// OAuth 回调本地回环服务的端口/host（单一真相源，供 CodexLoginService 起 NWListener、拼回调 URL 复用）。
    public static let callbackHost = "127.0.0.1"
    public static let callbackPort: UInt16 = 1455
    /// 授权服务器登记的 redirect_uri（值固定为 http://localhost:1455/auth/callback，端口复用 callbackPort）。
    public static let redirectURI = "http://localhost:\(callbackPort)/auth/callback"
    public static let scope = "openid profile email offline_access"
    /// 协议 originator（单一真相源，供授权 URL、Responses header、User-Agent 派生复用）。
    public static let originator = "openclaw"
    /// User-Agent 的 OS 段（拼在 originator 之后）：最终 UA = originator + 此段。
    public static let userAgentOSSegment = " (macOS)"
    /// 默认 User-Agent（originator + OS 段，单一真相源）：值与原内联 "\(originator) (macOS)" 逐字节一致。
    public static let defaultUserAgent = originator + userAgentOSSegment
    /// token 响应缺省 expires_in 时的兜底有效期（秒）。
    /// 注意须远大于 OAuthTokens.expiryLeeway，否则刚拿到的 token 会立即被判过期。
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

    /// 解析 token 响应为 OAuthTokens。refresh 响应可能不返回 refresh_token，用 fallback。
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
            // token 响应（成功状态码下）解码失败：只记错误类型与本地化描述，绝不打印响应体（避免泄露 token）；行为不变，照常抛 .invalidResponse。
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

    /// JWT payload 中我们关心的部分：["https://api.openai.com/auth"]["chatgpt_account_id"]。
    /// 用 Decodable 显式建模，避免 [String:Any] 取值时静默降级为空。
    private struct JWTPayload: Decodable {
        struct Auth: Decodable {
            let chatgpt_account_id: String?
        }
        let auth: Auth?
        private enum CodingKeys: String, CodingKey {
            case auth = "https://api.openai.com/auth"
        }
    }

    /// 解 JWT payload，取 ["https://api.openai.com/auth"]["chatgpt_account_id"]。
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
        // RFC 3986 unreserved 字符（含 _ - . ~）不编码，其余编码；
        // 保证 client_id 的下划线在 form body 中保持原样。
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
