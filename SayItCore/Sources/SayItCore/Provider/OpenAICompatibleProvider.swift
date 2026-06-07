import Foundation

/// 调用 OpenAI 兼容的 /chat/completions。provider-agnostic：凡走该协议的 Provider 均复用本类型
/// （当前 OpenAI / DeepSeek，及非 OAuth 的 OpenAI 视觉模型）。
/// Key 由调用方传入（不读 Keychain，保持可测）。
public struct OpenAICompatibleProvider: LLMProvider {
    private let config: ProviderConfig
    private let apiKey: String
    private let session: URLSession
    /// 是否把图片发给模型。OpenAI（gpt-4o 等支持视觉）传 true；DeepSeek（纯文本）保持 false。
    private let sendsImages: Bool

    /// 单次请求超时（秒）。非流式 chat/completions 一次性返回，给足整体上限即可。
    private static let requestTimeout = LLMDefaults.requestTimeout

    public init(config: ProviderConfig, apiKey: String, session: URLSession = .shared,
                sendsImages: Bool = false) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
        self.sendsImages = sendsImages
    }

    /// 图片 part 的 leaf：编为 `{"type":"image_url","image_url":{"url":...}}`，url 直接用 dataURL。
    private struct ImagePart: Encodable {
        struct URLBox: Encodable { let url: String }
        let type = "image_url"
        let image_url: URLBox
    }

    /// 一条 message 的 content：要么纯字符串（无图/不发图），要么 parts 数组（文本 part + 每张图一个 image_url part）。
    /// 多态骨架（string OR [text-part, image-parts...]）由 MultipartContent 提供；本类型只给出自己的 image_url leaf。
    /// 纯字符串分支与旧行为逐字节一致。
    private typealias WireContent = MultipartContent<ImagePart>

    /// 发给 chat/completions 的线上消息（content 可为字符串或 parts 数组）。
    private struct WireMessage: Encodable { let role: String; let content: WireContent }
    private struct RequestBody: Encodable {
        let model: String
        let messages: [WireMessage]
        let temperature: Double
    }
    private struct ResponseBody: Decodable {
        // content 设为可空：模型「回了但 content 为 null/缺失」时仍能解码（取值处兜底空串），
        // 不再因缺 content 抛 .invalidResponse。有 content 的正常路径不变。
        struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
        let choices: [Choice]
    }

    public func complete(messages: [LLMMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        guard let url = URL(string: config.baseURL + HTTPConstants.chatCompletionsPath) else {
            throw ProviderError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        req.setValue(HTTPConstants.applicationJSON, forHTTPHeaderField: HTTPConstants.contentTypeHeader)
        req.setBearerAuthorization(apiKey)
        let wire = messages.map {
            WireMessage(role: $0.role.rawValue, content: Self.wireContent(for: $0, sendsImages: sendsImages))
        }
        req.httpBody = try JSONEncoder().encode(
            RequestBody(model: config.model, messages: wire, temperature: LLMDefaults.temperature))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let http = try HTTPResponseValidator.httpResponse(from: response)
        try HTTPResponseValidator.throwIfHTTPError(http, body: String(data: data, encoding: .utf8) ?? "")
        guard let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let message = parsed.choices.first?.message else {
            // 成功状态码下却解不出 choices[].message：记录 body 片段助排查（行为不变，照常抛 .invalidResponse）。
            let snippet = String((String(data: data, encoding: .utf8) ?? "").prefix(500))
            NSLog("[SayIt][OpenAICompatible] HTTP %d 成功但 JSON 解码失败，body 片段=%@", http.statusCode, snippet)
            throw ProviderError.invalidResponse
        }
        // content 为 null/缺失（合法的空回复）兜底空串，不再误报 .invalidResponse；有 content 时原样返回。
        return message.content ?? ""
    }

    /// 把一条 LLMMessage 转成线上 content：
    /// 仅当 sendsImages 且该消息带图时，编码为 parts 数组（文本 part + 每张图 image_url part，url 直接用 dataURL）；
    /// 否则编码为纯字符串（与旧行为逐字节一致）。
    private static func wireContent(for msg: LLMMessage, sendsImages: Bool) -> WireContent {
        if sendsImages, !msg.imageDataURLs.isEmpty {
            let parts = msg.imageDataURLs.map { ImagePart(image_url: .init(url: $0)) }
            return .parts(text: msg.content, images: parts)
        }
        return .text(msg.content)
    }
}
