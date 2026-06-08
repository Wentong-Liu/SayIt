import Foundation

/// The single misheard -> corrected term pair an extraction yields: `heard` is the form as it appeared in SayIt's
/// transcribed/injected text, `corrected` is the user's fixed form. Both are short single terms (proper noun / brand /
/// personal name / code identifier) — never a phrase or sentence (the coordinator's hard guard enforces this structurally).
public struct LearnedTerm: Equatable, Sendable {
    public let heard: String
    public let corrected: String

    public init(heard: String, corrected: String) {
        self.heard = heard
        self.corrected = corrected
    }
}

/// Extracts the single corrected term from a (injected, final) text pair — the analysis half of the redesigned
/// "learn from edits" feature (Part B v2). Replaces the old local word-diff (`LearnedEditDetector`): a local diff cannot
/// segment Chinese-with-embedded-English (it offered the whole sentence), so extraction is delegated to the polish LLM.
///
/// A protocol seam so the coordinator can inject a FAKE in tests (the concrete impl needs a configured provider, which is
/// not available in a headless test run). Returns `nil` whenever the edit is NOT a single-term spelling/casing correction
/// (rephrasing, added/removed content, grammar/punctuation, ambiguous), or on any provider error/timeout.
public protocol LearnedTermExtracting: Sendable {
    /// Given the text SayIt injected and the final text the user committed, returns the single misheard -> corrected term
    /// worth learning, or `nil` when the edit is not a single-term correction (or extraction failed). Never throws —
    /// degrades to `nil` so the caller drops silently.
    func extract(injected: String, final: String) async -> LearnedTerm?
}

/// The provider-backed `LearnedTermExtracting`: builds a JSON-extraction prompt, calls the injected ``LLMProvider``
/// (constructed by the App layer exactly like the polish provider), and robustly parses the reply.
///
/// Robustness contract (never crash, never guess):
/// - provider throws / times out -> `nil`;
/// - reply is unparseable / not the expected JSON shape -> `nil`;
/// - the JSON pair is null (`{"heard": null, "corrected": null}`) -> `nil`.
///
/// There is no structured-output (`response_format` / `json_schema`) plumbing in the providers, so the reply is parsed as
/// plain text: code fences are stripped, the first `{...}` object is located, and `JSONDecoder` decodes it. The hard
/// single-term guard lives in the coordinator (so it applies regardless of which extractor is used).
public struct LearnedTermExtractor: LearnedTermExtracting {
    /// The provider used for extraction (constructed by the caller exactly like the polish provider). `any LLMProvider`
    /// so any configured backend (OpenAI / DeepSeek / Anthropic / ChatGPT OAuth) works without copy-pasting construction.
    private let provider: any LLMProvider

    /// The hard timeout for the extraction call: extraction must return within this, otherwise it is treated as failed
    /// and yields `nil` (never permanently stuck). Injectable so tests pass a tiny value.
    private let timeout: Duration

    /// - Parameters:
    ///   - provider: the LLM provider to call (same construction as polish).
    ///   - timeout: the hard extraction timeout; defaults to 20s. Tests pass a tiny value.
    public init(provider: any LLMProvider, timeout: Duration = .seconds(20)) {
        self.provider = provider
        self.timeout = timeout
    }

    public func extract(injected: String, final: String) async -> LearnedTerm? {
        let messages = Self.buildMessages(injected: injected, final: final)
        let reply: String
        do {
            reply = try await Self.withTimeout(timeout) {
                try await provider.complete(messages: messages)
            }
        } catch {
            // Any throw / timeout / cancellation -> drop silently.
            return nil
        }
        return Self.parse(reply)
    }

    // MARK: - Prompt

    /// Builds the extraction prompt. The system prompt requires a strict JSON object with the single corrected term, or a
    /// null pair when the edit is not a single-term correction; the examples pin the "single short term" behavior.
    static func buildMessages(injected: String, final: String) -> [LLMMessage] {
        let system = """
        You compare two versions of a piece of text: the ORIGINAL text that a dictation app inserted, and the FINAL text \
        after the user edited it in place. Your job is to detect whether the user corrected the spelling or casing of a \
        SINGLE short term — a proper noun, brand, product name, personal name, or code identifier — that the dictation \
        app misheard or misspelled.

        Respond with ONLY a JSON object, no prose, no code fence:
        {"heard": <the original form of the corrected term as it appeared in the ORIGINAL text>, "corrected": <the user's fixed form>}

        Rules:
        - "corrected" MUST be a SINGLE SHORT TERM (proper noun / brand / personal name / code identifier). It is NEVER a \
        phrase, a clause, or a whole sentence.
        - "heard" is that same term as it appeared in the ORIGINAL text (the form the app got wrong).
        - If the edit is NOT a single-term spelling/casing correction — i.e. it is a rephrasing, added or removed content, \
        a grammar or punctuation change, or anything ambiguous — respond with {"heard": null, "corrected": null}.

        Examples:
        ORIGINAL: "I added a use effect hook." FINAL: "I added a useEffect hook." -> {"heard": "use effect", "corrected": "useEffect"}
        ORIGINAL: "我之前用过Type+和闪电书。" FINAL: "我之前用过Typeless和闪电书。" -> {"heard": "Type+", "corrected": "Typeless"}
        ORIGINAL: "Let's meet tomorrow." FINAL: "Let's meet on Tuesday instead." -> {"heard": null, "corrected": null}
        """
        let user = """
        ORIGINAL: \(injected)
        FINAL: \(final)
        """
        return [
            LLMMessage(role: .system, content: system),
            LLMMessage(role: .user, content: user),
        ]
    }

    // MARK: - Parsing

    /// The decodable shape of the model's JSON reply. Optional fields so the null pair decodes to `nil`s.
    private struct Reply: Decodable {
        let heard: String?
        let corrected: String?
    }

    /// Robustly parses the model reply into a ``LearnedTerm``, or `nil`. Strips code fences, locates the first balanced
    /// `{...}` object, and decodes it. A null pair (or any missing/empty field) yields `nil`. The single-term hard guard
    /// is applied by the caller, not here.
    static func parse(_ reply: String) -> LearnedTerm? {
        guard let jsonSlice = firstJSONObject(in: reply) else { return nil }
        guard let data = jsonSlice.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        guard let heard = decoded.heard, let corrected = decoded.corrected else { return nil }
        let trimmedHeard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHeard.isEmpty, !trimmedCorrected.isEmpty else { return nil }
        return LearnedTerm(heard: trimmedHeard, corrected: trimmedCorrected)
    }

    /// Returns the substring spanning the first top-level `{...}` object in `text` (brace-balanced), or `nil` if none.
    /// Handles a leading code fence / prose by scanning for the first `{` and matching braces (string-literal aware so a
    /// `}` inside a JSON string value does not close the object early).
    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                switch char {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Timeout

    /// The marker error thrown when the work exceeds the timeout.
    private struct ExtractTimeout: Error {}

    /// Runs `work` with a hard timeout: whoever finishes first wins; the other branch is cancelled. Mirrors the
    /// coordinator's transcribe-timeout pattern (a throwing task group) so the call can never hang indefinitely.
    private static func withTimeout(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ExtractTimeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ExtractTimeout() }
            return result
        }
    }
}
