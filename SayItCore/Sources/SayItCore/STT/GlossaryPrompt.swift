import Foundation

/// Shared, pure builder for the user-dictionary STT biasing glossary text.
///
/// User-dictionary **Layer 1** biases speech-to-text toward the user's dictionary terms (a best-effort recall boost).
/// Both transcribers consume the *same* compact glossary string so local (WhisperKit `promptTokens`) and cloud
/// (OpenAI-compatible `prompt`) biasing stay identical:
/// - the **local** path feeds this text into `tokenizer.encode(text:)` to build `DecodingOptions.promptTokens`;
/// - the **cloud** path sends this text verbatim as the multipart `prompt` field.
///
/// The output is a deduplicated, blank-stripped, comma-joined list of canonical terms, ordered **most-relevant LAST**
/// (highest `usageCount` nearest the decode start, where prompt conditioning is strongest). It is purely advisory:
/// biasing only improves recall; exact casing is still guaranteed downstream by the deterministic rewriter and the polish LLM.
public enum GlossaryPrompt {
    /// The separator joining canonical terms in the glossary string (comma + space, mirroring a natural word list).
    static let separator = ", "

    /// Builds the compact glossary string from a list of canonical terms.
    ///
    /// Steps (all pure, deterministic): trim each term, drop blanks, dedupe (keeping the *highest*-priority occurrence),
    /// order by `usageCount` ascending (so the most-used term sits LAST), then join with ``separator``.
    ///
    /// - Parameter terms: the candidate `(canonical, usageCount)` pairs, typically the enabled dictionary entries.
    /// - Returns: a comma-joined glossary string, or `""` when there is nothing to bias toward (empty dictionary).
    static func compactList(from terms: [Term]) -> String {
        // Stable sort by usageCount ascending: lowest-usage first, highest-usage last (most relevant nearest decode start).
        // `enumerated` preserves the original input order as a tiebreaker so equal-usage terms keep a deterministic layout.
        let ordered = terms.enumerated().sorted { lhs, rhs in
            if lhs.element.usageCount != rhs.element.usageCount {
                return lhs.element.usageCount < rhs.element.usageCount
            }
            return lhs.offset < rhs.offset
        }

        var seen = Set<String>()
        var result: [String] = []
        for pair in ordered {
            let trimmed = pair.element.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Dedupe case-insensitively on a normalized key (a glossary need list each surface term only once).
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result.joined(separator: separator)
    }

    /// Convenience overload: builds the glossary string straight from the enabled dictionary entries' canonical + usage.
    static func compactList(from entries: [DictionaryEntry]) -> String {
        compactList(from: entries.map { Term(canonical: $0.canonical, usageCount: $0.usageCount) })
    }

    /// A minimal `(canonical, usageCount)` pair, decoupled from ``DictionaryEntry`` so the builder stays trivially unit-testable.
    struct Term: Equatable, Sendable {
        let canonical: String
        let usageCount: Int

        init(canonical: String, usageCount: Int = 0) {
            self.canonical = canonical
            self.usageCount = usageCount
        }
    }
}
