import Foundation

/// 调用 Anthropic（Claude）Messages API（POST /messages，非流式）。
/// Anthropic 协议与 OpenAI 不兼容：system 走顶层字段、鉴权用 x-api-key、content 可为字符串或内容块数组。
/// Key 由调用方传入（不读 Keychain，保持可测）。
public struct AnthropicProvider: LLMProvider {
    private let config: ProviderConfig
    private let apiKey: String
    private let session: URLSession

    /// 单次请求超时（秒）。非流式 messages 一次性返回，给足整体上限即可。
    private static let requestTimeout = LLMDefaults.requestTimeout
    /// Anthropic API 版本头（固定）。
    private static let apiVersion = "2023-06-01"

    public init(config: ProviderConfig, apiKey: String, session: URLSession = .shared) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - 线上请求模型

    /// 图片内容块的 source（base64）。
    private struct WireImageSource: Encodable {
        let type = "base64"
        let media_type: String
        let data: String
    }

    /// 图片块的 leaf：编为 `{"type":"image","source":{...}}`。
    private struct ImageBlock: Encodable { let type = "image"; let source: WireImageSource }

    /// 一条 message 的 content：要么是纯字符串，要么是内容块数组（文本块 + 图片块）。
    /// 多态骨架（string OR [text-block, image-blocks...]）由 MultipartContent 提供；本类型只给出自己的 image leaf。
    private typealias WireContent = MultipartContent<ImageBlock>

    private struct WireMessage: Encodable { let role: String; let content: WireContent }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let temperature: Double
        /// 为空时省略（Optional + 自动省略 nil）。
        let system: String?
        let messages: [WireMessage]
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
    }

    // MARK: - 调用

    public func complete(messages: [LLMMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        guard let url = URL(string: config.baseURL + HTTPConstants.messagesPath) else {
            throw ProviderError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        req.setValue(HTTPConstants.applicationJSON, forHTTPHeaderField: HTTPConstants.contentTypeHeader)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        // system 走顶层字段：所有 role==.system 的 content 用两个换行连接；为空则省略。
        let systemText = messages.filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let system: String? = systemText.isEmpty ? nil : systemText

        // 其余消息进 messages 数组；.user -> "user"，.assistant -> "assistant"。
        let wire: [WireMessage] = messages.compactMap { msg in
            let role: String
            switch msg.role {
            case .system: return nil
            case .user: role = "user"
            case .assistant: role = "assistant"
            }
            return WireMessage(role: role, content: Self.wireContent(for: msg))
        }

        req.httpBody = try JSONEncoder().encode(
            RequestBody(model: config.model, max_tokens: LLMDefaults.maxTokens, temperature: LLMDefaults.temperature,
                        system: system, messages: wire))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let http = try HTTPResponseValidator.httpResponse(from: response)
        try HTTPResponseValidator.throwIfHTTPError(http, body: String(data: data, encoding: .utf8) ?? "")
        guard let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            // 成功状态码下却解不出 content 块数组：记录 body 片段助排查（行为不变，照常抛 .invalidResponse）。
            let snippet = String((String(data: data, encoding: .utf8) ?? "").prefix(500))
            NSLog("[SayIt][Anthropic] HTTP %d 成功但 JSON 解码失败，body 片段=%@", http.statusCode, snippet)
            throw ProviderError.invalidResponse
        }
        return parsed.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
    }

    /// 把一条 LLMMessage 转成线上 content：无图直接字符串，有图则「文本块 + 图片块数组」。
    private static func wireContent(for msg: LLMMessage) -> WireContent {
        let blocks = msg.imageDataURLs.compactMap(parseDataURL).map(ImageBlock.init(source:))
        if blocks.isEmpty { return .text(msg.content) }
        return .parts(text: msg.content, images: blocks)
    }

    /// 解析 "data:image/png;base64,XXXX" 形式：取 data: 与 ;base64 之间为 media_type、逗号后为 base64。
    /// 解析不出的返回 nil（调用方跳过该图）。
    private static func parseDataURL(_ s: String) -> WireImageSource? {
        guard s.hasPrefix("data:"),
              let semicolon = s.range(of: ";base64,") else { return nil }
        let mediaType = String(s[s.index(s.startIndex, offsetBy: 5)..<semicolon.lowerBound])
        let base64 = String(s[semicolon.upperBound...])
        guard !mediaType.isEmpty, !base64.isEmpty else { return nil }
        return WireImageSource(media_type: mediaType, data: base64)
    }
}
