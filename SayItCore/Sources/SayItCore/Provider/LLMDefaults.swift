import Foundation

/// Sampling/timeout defaults shared by all LLM Providers (single source of truth).
/// Changing them here affects all Providers at once, avoiding magic-number drift across multiple places.
enum LLMDefaults {
    /// Sampling temperature. Deliberately LOW: every workload these Providers run is deterministic cleanup —
    /// polish (whose hard constraint #1 is "整理不回答 / never change meaning") and learned-term extraction
    /// (stable structured output). A low temperature favors faithful, low-variance, repeatable results rather
    /// than creative variation. (CodexResponsesProvider sends no temperature at all, the same intent.)
    static let temperature: Double = 0.2
    /// Max token count per reply (only the Anthropic protocol needs it passed explicitly; the OpenAI-compatible protocol uses the server default).
    static let maxTokens: Int = 1024
    /// Timeout (seconds) for a single (non-streaming) request. Returns all at once, so just give a generous overall ceiling.
    static let requestTimeout: TimeInterval = 60
}
