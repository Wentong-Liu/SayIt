import Foundation
import os

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

    /// Diagnostics-only logger (observability, no behavior). `.notice`/`.error` level so lines surface in
    /// `log stream --predicate 'subsystem == "com.liuwentong.SayIt"'`; reuses the existing subsystem with the dedicated
    /// `learn` category shared with the coordinator. `static` so it fits this `Sendable` value type and is reachable from
    /// the non-mutating `extract`. Debug text is interpolated with `privacy: .public` (active on-device debugging).
    private static let log = Logger(subsystem: "com.liuwentong.SayIt", category: "learn")

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
        Self.log.notice("extractor: calling provider")
        do {
            reply = try await Self.withTimeout(timeout) {
                try await provider.complete(messages: messages)
            }
        } catch {
            // Any throw / timeout / cancellation -> drop silently.
            Self.log.error("extractor: provider threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let result = Self.parse(reply)
        Self.log.notice("extractor: raw=\(String(reply.prefix(500)), privacy: .public)")
        Self.log.notice("extractor: parsed=\(result == nil ? "nil" : "term", privacy: .public)")
        return result
    }

    // MARK: - Prompt

    /// Builds the extraction prompt. The system prompt tells the model the ORIGINAL is raw speech-to-text output (so its
    /// errors are PHONETIC / sound-alike — a term misheard, or one term split into several sound-alike words), asks it to
    /// align the garbled "heard" form to the user's "corrected" form via pronunciation + context, and to stay robust to
    /// incidental ordinary-word edits (return the term anyway). It requires a strict JSON object with the single corrected
    /// term, or a null pair only when there is NO term correction at all; the examples pin the phonetic + robustness behavior.
    static func buildMessages(injected: String, final: String) -> [LLMMessage] {
        let system = """
        You compare two versions of a piece of text. The ORIGINAL is the RAW OUTPUT of a SPEECH-TO-TEXT recognizer, so its \
        mistakes are PHONETIC / sound-alike: a term was MISHEARD (it sounds similar but is the wrong word), or ONE term was \
        split into SEVERAL sound-alike words. These are NOT typos. The FINAL is the text AFTER the user edited it in place to \
        fix the recognizer.

        Your job: find the SINGLE proper noun, brand, product name, personal name, or code identifier that the user \
        corrected. Align the garbled ORIGINAL form ("heard", which may be ONE word OR SEVERAL adjacent words) to the user's \
        FINAL form ("corrected") using PRONUNCIATION similarity together with the surrounding CONTEXT (the topic of the \
        sentence tells you which term was meant).

        Respond with ONLY a JSON object, no prose, no code fence:
        {"heard": <the original form of the corrected term as it appeared in the ORIGINAL text>, "corrected": <the user's fixed form>}

        Rules:
        - "corrected" MUST be a SINGLE SHORT TERM (proper noun / brand / product name / personal name / code identifier). It \
        is NEVER a phrase, a clause, or a whole sentence.
        - "heard" is that same term as it appeared in the ORIGINAL text (the form the recognizer got wrong); it may span ONE \
        or SEVERAL adjacent words.
        - BE ROBUST TO INCIDENTAL EDITS: if there are OTHER small or ordinary-word differences between ORIGINAL and FINAL \
        that are NOT proper-noun / term corrections, IGNORE them and STILL return the one term correction.
        - Return {"heard": null, "corrected": null} ONLY when there is NO proper-noun / term / identifier correction at all — \
        i.e. the change is pure rephrasing, grammar, punctuation, or added/removed content.

        Examples:
        ORIGINAL: "I added a use effect hook." FINAL: "I added a useEffect hook." -> {"heard": "use effect", "corrected": "useEffect"}
        ORIGINAL: "我之前用过 Tables 和闪电书。" FINAL: "我之前用过 Typeless 和闪电书。" -> {"heard": "Tables", "corrected": "Typeless"}
        ORIGINAL: "Let's check Trading Will for the chart." FINAL: "Let's check TradingView for the chart." -> {"heard": "Trading Will", "corrected": "TradingView"}
        ORIGINAL: "我之前用过 Tables 和闪电书。" FINAL: "我之前用过 Typeless 和闪电说。" -> {"heard": "Tables", "corrected": "Typeless"}
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
