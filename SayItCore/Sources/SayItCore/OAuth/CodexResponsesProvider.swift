import Foundation
import os

/// Uses the ChatGPT(Codex) OAuth token to call codex/responses (Responses API + SSE).
/// Maps [LLMMessage] to instructions (system) + input (the rest), streamingly accumulating output_text.delta.
public struct CodexResponsesProvider: LLMProvider {
    private let accessToken: String
    private let accountId: String
    private let model: String
    private let userAgent: String
    private let session: URLSession

    /// The connection/response timeout (seconds) for a single request.
    private static let requestTimeout = LLMDefaults.requestTimeout
    /// The overall ceiling (seconds) of the SSE read loop: beyond it the stream is judged stalled and fails, avoiding an infinite hang.
    /// Must be >= requestTimeout: requestTimeout only covers connecting/first byte, while the stream-level timeout must wrap the entire streamed read;
    /// a smaller value would wrongly kill a normal long reply before it finishes reading; so this must always be greater than or equal to the single-request timeout.
    private static let maxStreamSeconds: TimeInterval = 90
    /// The data prefix of an SSE line (shared by prefix-checking and prefix-stripping, avoiding writing the same string twice).
    private static let dataPrefix = "data:"
    /// Observability-only logger for polish failures (HTTP non-2xx / stream timeout / stream-failed event).
    /// `nonisolated static` so it is reachable from the static `readStream` and the `@Sendable` task-group closures.
    /// NEVER interpolate the bearer token / Authorization header here -- only server-side status codes and truncated error bodies are logged.
    private nonisolated static let log = Logger(subsystem: SayItCore.identifier, category: "polish")

    public init(accessToken: String, accountId: String, model: String,
                userAgent: String = ChatGPTOAuth.defaultUserAgent, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.model = model
        self.userAgent = userAgent
        self.session = session
    }

    /// One item in input[].content: a text item (input_text/output_text) or an image item (input_image).
    /// Uses a custom Encodable to express this polymorphism -- the encoded keys are equivalent to the old [String:Any]:
    /// text item {type,text}, image item {type,image_url}.
    private enum ContentItem: Encodable {
        case text(type: String, text: String)
        case image(url: String)

        private enum CodingKeys: String, CodingKey { case type, text, image_url }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(type, text):
                try c.encode(type, forKey: .type)
                try c.encode(text, forKey: .text)
            case let .image(url):
                try c.encode("input_image", forKey: .type)
                try c.encode(url, forKey: .image_url)
            }
        }
    }

    /// One input message: role + an array of content items.
    private struct InputMessage: Encodable {
        let role: String
        let content: [ContentItem]
    }

    /// The strongly-typed parse body of a single SSE event (replacing the old weakly-typed JSONSerialization as? [String:Any] key access):
    /// only cares about type (the event type) and delta (the incremental text, present only for output_text.delta), both optional --
    /// it parses the same events, the type key and delta value semantics match the old implementation, and the normal delta increment is byte-for-byte unchanged.
    private struct StreamEvent: Decodable {
        let type: String?
        let delta: String?
    }

    /// The text field: {"verbosity":"low"}.
    private struct TextOption: Encodable { let verbosity: String }

    /// The reasoning field: {"effort":"none"}.
    /// Polish is trivial text cleanup needing no reasoning; "none" turns reasoning fully off for maximum speed
    /// (GPT-5.5 otherwise defaults to "xhigh"). Valid effort values: none/low/medium/high/xhigh.
    private struct ReasoningOption: Encodable { let effort: String }

    /// The Responses API request body: instructions (system prompt) + input (message sequence) + streaming/tool toggles, with type-safe keys.
    private struct RequestBody: Encodable {
        let model: String
        let store: Bool
        let stream: Bool
        let instructions: String
        let input: [InputMessage]
        let text: TextOption
        let reasoning: ReasoningOption
        let include: [String]
        let tool_choice: String
        let parallel_tool_calls: Bool
    }

    public func complete(messages: [LLMMessage]) async throws -> String {
        guard !accessToken.isEmpty else { throw ProviderError.missingAPIKey }
        let system = messages.first(where: { $0.role == .system })?.content ?? "You are a helpful assistant."
        let input: [InputMessage] = messages.filter { $0.role != .system }.map { message in
            let type = (message.role == .assistant) ? "output_text" : "input_text"
            var content: [ContentItem] = [.text(type: type, text: message.content)]
            for url in message.imageDataURLs {
                content.append(.image(url: url))
            }
            return InputMessage(role: message.role.rawValue, content: content)
        }
        let body = RequestBody(
            model: model,
            store: false,
            stream: true,
            instructions: system,
            input: input,
            text: TextOption(verbosity: "low"),
            reasoning: ReasoningOption(effort: "none"),
            include: ["reasoning.encrypted_content"],
            tool_choice: "auto",
            parallel_tool_calls: true)
        guard let url = URL(string: ChatGPTOAuth.responsesEndpoint) else {
            throw ProviderError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        req.setBearerAuthorization(accessToken)
        req.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue(ChatGPTOAuth.originator, forHTTPHeaderField: "originator")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("text/event-stream", forHTTPHeaderField: HTTPConstants.acceptHeader)
        req.setValue(HTTPConstants.applicationJSON, forHTTPHeaderField: HTTPConstants.contentTypeHeader)
        // Configures .withoutEscapingSlashes to preserve the original JSONSerialization output behavior (the dataURL in image_url contains /, not escaped).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        req.httpBody = try encoder.encode(body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let http = try HTTPResponseValidator.httpResponse(from: response)
        if !HTTPResponseValidator.successRange.contains(http.statusCode) {
            // Read all the remaining body for error reporting (joined by newline, preserving each line's boundary).
            var errLines: [String] = []
            for try await line in bytes.lines { errLines.append(line) }
            let body = errLines.joined(separator: "\n")
            // Observability: surface the HTTP status + a truncated server error body (e.g. a 400 rejecting effort="none").
            // The bearer token lives only in a request header and is never interpolated here.
            Self.log.error("polish HTTP \(http.statusCode, privacy: .public): \(String(body.prefix(500)), privacy: .public)")
            try HTTPResponseValidator.throwIfHTTPError(http, body: body)
        }

        // Stream-level timeout: the old implementation used "compare systemUptime each time a line enters the loop" for the timeout; when upstream half-opens and hangs,
        // for-await is forever stuck waiting for the next line and the timeout branch never fires -> the whole request hangs dead. Switched to withThrowingTaskGroup
        // to race "read stream" against "Task.sleep(maxStreamSeconds)": if the read stream finishes first, cancel the timer and return;
        // if the timer fires first, throw streamFailed and cancel the read stream with the group (AsyncBytes iteration responds to cancellation, the half-open connection is abandoned).
        let decoder = JSONDecoder()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.readStream(bytes, decoder: decoder)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.maxStreamSeconds))
                let msg = "stream timed out after \(Int(Self.maxStreamSeconds))s"
                Self.log.error("polish stream timeout: \(msg, privacy: .public)")
                throw ProviderError.streamFailed(body: msg)
            }
            // Whichever finishes first wins: the read stream returns text successfully -> cancel the timer; the timer fires first -> its throw propagates up and cancels the read stream.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Reads SSE line by line, accumulating output_text.delta; on a terminal event returns the accumulated text, on an error event throws.
    /// The normal delta increment is byte-for-byte unchanged (it parses the same events, with the same type/delta key access).
    private static func readStream(_ bytes: URLSession.AsyncBytes, decoder: JSONDecoder) async throws -> String {
        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix(Self.dataPrefix) else { continue }
            let payload = line.dropFirst(Self.dataPrefix.count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let payloadData = payload.data(using: .utf8),
                  let event = try? decoder.decode(StreamEvent.self, from: payloadData),
                  let type = event.type else { continue }
            switch type {
            case "response.output_text.delta":
                if let delta = event.delta { text += delta }
            case "response.completed", "response.done", "response.incomplete":
                return text
            case "error", "response.failed":
                // No HTTP status available at the SSE layer -- log the truncated payload only (the server's error detail).
                Self.log.error("polish stream failed: \(String(payload.prefix(500)), privacy: .public)")
                throw ProviderError.streamFailed(body: payload)
            default:
                continue
            }
        }
        // The stream ended naturally without receiving a response.completed/done/incomplete terminal event: logged to aid debugging (behavior unchanged, still returns the accumulated text).
        NSLog("[SayIt][CodexResponses] SSE 流结束但未收到终止事件，返回已累积文本 长度=%d", text.count)
        return text
    }
}
