import Foundation

/// Calls the Anthropic (Claude) Messages API (POST /messages, non-streaming).
/// The Anthropic protocol is incompatible with OpenAI: system goes in a top-level field, auth uses x-api-key, content can be a string or an array of content blocks.
/// The Key is passed in by the caller (does not read the Keychain, staying testable).
public struct AnthropicProvider: LLMProvider {
    private let config: ProviderConfig
    private let apiKey: String
    private let session: URLSession

    /// Single-request timeout (seconds). Non-streaming messages return all at once, so just give a generous overall ceiling.
    private static let requestTimeout = LLMDefaults.requestTimeout
    /// The Anthropic API version header (fixed).
    private static let apiVersion = "2023-06-01"

    public init(config: ProviderConfig, apiKey: String, session: URLSession = .shared) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Wire request model

    /// The source (base64) of an image content block.
    private struct WireImageSource: Encodable {
        let type = "base64"
        let media_type: String
        let data: String
    }

    /// The image block's leaf: encoded as `{"type":"image","source":{...}}`.
    private struct ImageBlock: Encodable { let type = "image"; let source: WireImageSource }

    /// The content of a message: either a plain string, or an array of content blocks (text blocks + image blocks).
    /// The polymorphic skeleton (string OR [text-block, image-blocks...]) is provided by MultipartContent; this type only supplies its own image leaf.
    private typealias WireContent = MultipartContent<ImageBlock>

    private struct WireMessage: Encodable { let role: String; let content: WireContent }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let temperature: Double
        /// Omitted when empty (Optional + automatic nil omission).
        let system: String?
        let messages: [WireMessage]
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
    }

    // MARK: - Call

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

        // system goes in the top-level field: all role==.system content is joined with two newlines; omitted if empty.
        let systemText = messages.filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let system: String? = systemText.isEmpty ? nil : systemText

        // The remaining messages go into the messages array; .user -> "user", .assistant -> "assistant".
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
            // Under a success status code yet the content block array cannot be parsed: log a body fragment to aid debugging (behavior unchanged, still throws .invalidResponse).
            HTTPResponseValidator.logDecodeFailure(tag: "Anthropic", statusCode: http.statusCode, data: data)
            throw ProviderError.invalidResponse
        }
        return parsed.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
    }

    /// Converts one LLMMessage into wire content: without images, a direct string; with images, a "text block + image block array".
    private static func wireContent(for msg: LLMMessage) -> WireContent {
        let blocks = msg.imageDataURLs.compactMap(parseDataURL).map(ImageBlock.init(source:))
        if blocks.isEmpty { return .text(msg.content) }
        return .parts(text: msg.content, images: blocks)
    }

    /// Parses the "data:image/png;base64,XXXX" form: takes the part between data: and ;base64 as the media_type, the part after the comma as base64.
    /// Returns nil if it cannot be parsed (the caller skips that image).
    private static func parseDataURL(_ s: String) -> WireImageSource? {
        guard s.hasPrefix("data:"),
              let semicolon = s.range(of: ";base64,") else { return nil }
        let mediaType = String(s[s.index(s.startIndex, offsetBy: 5)..<semicolon.lowerBound])
        let base64 = String(s[semicolon.upperBound...])
        guard !mediaType.isEmpty, !base64.isEmpty else { return nil }
        return WireImageSource(media_type: mediaType, data: base64)
    }
}
