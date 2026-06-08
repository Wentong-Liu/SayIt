import Foundation

/// Calls the OpenAI-compatible /chat/completions. Provider-agnostic: every Provider using this protocol reuses this type
/// (currently OpenAI / DeepSeek, and the non-OAuth OpenAI vision model).
/// The Key is passed in by the caller (does not read the Keychain, staying testable).
public struct OpenAICompatibleProvider: LLMProvider {
    private let config: ProviderConfig
    private let apiKey: String
    private let session: URLSession
    /// Whether to send images to the model. OpenAI (gpt-4o etc. supporting vision) passes true; DeepSeek (text-only) stays false.
    private let sendsImages: Bool

    /// Single-request timeout (seconds). Non-streaming chat/completions returns all at once, so just give a generous overall ceiling.
    private static let requestTimeout = LLMDefaults.requestTimeout

    public init(config: ProviderConfig, apiKey: String, session: URLSession = .shared,
                sendsImages: Bool = false) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
        self.sendsImages = sendsImages
    }

    /// The image part's leaf: encoded as `{"type":"image_url","image_url":{"url":...}}`, the url directly uses the dataURL.
    private struct ImagePart: Encodable {
        struct URLBox: Encodable { let url: String }
        let type = "image_url"
        let image_url: URLBox
    }

    /// The content of a message: either a plain string (no images/not sending images), or a parts array (text part + one image_url part per image).
    /// The polymorphic skeleton (string OR [text-part, image-parts...]) is provided by MultipartContent; this type only supplies its own image_url leaf.
    /// The plain-string branch is byte-for-byte identical to the old behavior.
    private typealias WireContent = MultipartContent<ImagePart>

    /// The wire message sent to chat/completions (content can be a string or a parts array).
    private struct WireMessage: Encodable { let role: String; let content: WireContent }
    private struct RequestBody: Encodable {
        let model: String
        let messages: [WireMessage]
        let temperature: Double
        /// Model-aware lowest reasoning tier, so our trivial text-cleanup/extraction polish runs with as little
        /// reasoning latency as the chosen model allows. It is Optional/model-aware because the floor is NOT
        /// universal: gpt-5.5 supports the no-reasoning "none" tier, but the default BYO model gpt-5.4-mini and
        /// gpt-5-mini only go down to "minimal" — sending an unsupported effort returns HTTP 400 and would make
        /// every polish fail. Non-OpenAI providers (DeepSeek) do not accept this field at all, so it stays nil.
        /// Auto-synthesized Encodable uses encodeIfPresent for Optionals, so a nil value is omitted from the JSON
        /// (the DeepSeek request body stays byte-for-byte identical to before).
        let reasoning_effort: String?
    }
    private struct ResponseBody: Decodable {
        // content is set nullable: when the model "replied but content is null/missing" it can still decode (falling back to an empty string where read),
        // no longer throwing .invalidResponse due to missing content. The normal path with content is unchanged.
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
        // Only OpenAI's chat/completions accepts reasoning_effort; DeepSeek (and any other provider) gets nil → omitted.
        let reasoningEffort = config.name == "OpenAI" ? Self.lowestReasoningEffort(forModel: config.model) : nil
        req.httpBody = try JSONEncoder().encode(
            RequestBody(model: config.model, messages: wire, temperature: LLMDefaults.temperature,
                        reasoning_effort: reasoningEffort))

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
            // Under a success status code yet choices[].message cannot be parsed: log a body fragment to aid debugging (behavior unchanged, still throws .invalidResponse).
            let snippet = String((String(data: data, encoding: .utf8) ?? "").prefix(500))
            NSLog("[SayIt][OpenAICompatible] HTTP %d 成功但 JSON 解码失败，body 片段=%@", http.statusCode, snippet)
            throw ProviderError.invalidResponse
        }
        // content is null/missing (a legal empty reply) falls back to an empty string, no longer falsely reporting .invalidResponse; when there is content it is returned as-is.
        return message.content ?? ""
    }

    /// Converts one LLMMessage into wire content:
    /// only when sendsImages and the message has images, encodes into a parts array (text part + one image_url part per image, the url directly uses the dataURL);
    /// otherwise encodes into a plain string (byte-for-byte identical to the old behavior).
    private static func wireContent(for msg: LLMMessage, sendsImages: Bool) -> WireContent {
        if sendsImages, !msg.imageDataURLs.isEmpty {
            let parts = msg.imageDataURLs.map { ImagePart(image_url: .init(url: $0)) }
            return .parts(text: msg.content, images: parts)
        }
        return .text(msg.content)
    }

    /// Maps an OpenAI model id to the LOWEST reasoning tier that model accepts, so the polish request asks for
    /// as little reasoning latency as possible without ever sending a value the API would reject. The floor is
    /// model-aware: gpt-5.5 supports the new no-reasoning "none" tier, but the default BYO model gpt-5.4-mini and
    /// gpt-5-mini (GPT-5 / GPT-5.4 era) only go down to "minimal" — they return HTTP 400 on "none", which would
    /// make every polish fail. Substring match on "5.5" targets gpt-5.5 without matching gpt-5.4-mini / gpt-5-mini.
    private static func lowestReasoningEffort(forModel model: String) -> String {
        model.contains("5.5") ? "none" : "minimal"
    }
}
