import Foundation

/// Layer 2 candidate selection for the polish LLM glossary (see design brief Section 2).
///
/// Picks a **relevant subset** of user-dictionary entries to feed into the polish system prompt, so the model can spell
/// canonical forms in context (the Typeless-style "the AI figures out where a term is used" behaviour).
///
/// Design stance (kept deliberately **simple and self-contained**):
/// - This helper does NOT depend on ``DictionaryMatcher`` internals (a concurrent task is reworking the matcher);
///   it implements its own cheap lexical / token presence check so the two evolve independently.
/// - Pure function: same `(transcript, entries, cap)` always yields the same subset (stable ordering), so the
///   downstream prompt stays a pure function and is easy to unit-test.
/// - "Don't stuff hundreds of terms": when the whole enabled dictionary is small (<= `cap`) include all enabled
///   entries; otherwise keep only entries whose canonical/variant forms plausibly appear in the transcript, then cap.
public enum DictionaryGlossary {

    /// The default upper bound on the number of glossary entries injected into the prompt (design brief: ~30-50).
    public static let defaultCap = 50

    /// Selects the relevant subset of dictionary entries for the given transcript.
    ///
    /// Steps (per the Layer 2 design):
    /// 1. Keep only enabled entries (`entry.enabled == true`). Scope filtering is intentionally NOT applied here,
    ///    mirroring Layer 3's current "apply all enabled" stance (scope logic is a later concern).
    /// 2. If the whole enabled dictionary is small (`<= cap`), include all of it without filtering (per requirement).
    /// 3. Otherwise keep entries whose canonical or an obvious spoken form (lowercased / de-camelCased /
    ///    hyphen-or-underscore split) — or one of their existing variants — appears in the transcript, then cap.
    /// - Parameters:
    ///   - transcript: the raw dictation text being polished.
    ///   - entries: all dictionary entries (typically from `DictionaryStore.all()`).
    ///   - cap: the maximum number of entries to return; defaults to ``defaultCap``.
    /// - Returns: a deterministically ordered subset of enabled entries (deduped by canonical).
    public static func relevantSubset(for transcript: String,
                                      entries: [DictionaryEntry],
                                      cap: Int = defaultCap) -> [DictionaryEntry] {
        // 1) Only enabled entries participate; also drop entries with a blank canonical (nothing to inject).
        let enabled = entries.filter { entry in
            entry.enabled && !entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !enabled.isEmpty else { return [] }

        // Dedupe by canonical up front so both the "small dictionary" and the "filtered" paths return unique terms.
        let unique = dedupedByCanonical(enabled)

        // 2) Small dictionary: include all enabled entries (preserve their original order for stability).
        if unique.count <= cap {
            return unique
        }

        // 3) Large dictionary: keep only entries that plausibly appear in the transcript.
        let haystack = transcript.lowercased()
        // A separator-normalized haystack (hyphen/underscore -> space) lets multi-word spoken forms match the
        // "hyphen vs space" variant symmetrically, e.g. "use-effect" in the transcript matching "use effect".
        let normalizedHaystack = splitSeparators(haystack)
        let tokens = tokenSet(of: haystack)
        let matched = unique.filter {
            matches($0, haystack: haystack, normalizedHaystack: normalizedHaystack, tokens: tokens)
        }

        // Stable ordering for the cap: prefer higher usageCount, then most-recent createdAt (newer first),
        // then canonical for a fully deterministic tie-break.
        let ranked = matched.sorted { lhs, rhs in
            if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.canonical < rhs.canonical
        }
        return Array(ranked.prefix(cap))
    }

    // MARK: - Matching

    /// Whether any cheap "spoken form" of the entry appears in the lowercased transcript.
    ///
    /// Forms considered (all lowercased): the canonical, its de-camelCased form, its hyphen/underscore-split form,
    /// and every declared variant (variants may be empty today). Short forms (<= 2 chars) require token membership
    /// to avoid noisy substring hits; longer forms use a cheap `contains` substring check, also tested against a
    /// separator-normalized haystack so the "hyphen vs space" variant matches.
    static func matches(_ entry: DictionaryEntry,
                        haystack: String,
                        normalizedHaystack: String,
                        tokens: Set<String>) -> Bool {
        for form in spokenForms(for: entry)
        where formAppears(form, haystack: haystack, normalizedHaystack: normalizedHaystack, tokens: tokens) {
            return true
        }
        return false
    }

    /// Derives the cheap lowercased "spoken forms" for one entry: canonical + de-camelCase + hyphen/underscore split + variants.
    static func spokenForms(for entry: DictionaryEntry) -> [String] {
        var forms: [String] = []
        forms.append(entry.canonical)
        forms.append(deCamelCased(entry.canonical))
        forms.append(splitSeparators(entry.canonical))
        forms.append(contentsOf: entry.variants)

        // Lowercase and trim; drop empties and dedupe while preserving order.
        var seen = Set<String>()
        var result: [String] = []
        for form in forms {
            let normalized = form.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    /// Whether a single (already lowercased) form appears in the transcript.
    /// Forms of length <= 2 require a word-token match (avoids e.g. "go" matching inside "good"); longer forms use
    /// substring, against both the raw haystack and the separator-normalized one (hyphen vs space tolerance).
    private static func formAppears(_ form: String,
                                    haystack: String,
                                    normalizedHaystack: String,
                                    tokens: Set<String>) -> Bool {
        guard !form.isEmpty else { return false }
        if form.count <= 2 {
            // Very short forms: only a whole-token hit counts (substring would be too noisy).
            // A multi-word short form (rare) also falls back to substring since it cannot be a single token.
            if form.contains(" ") { return haystack.contains(form) || normalizedHaystack.contains(form) }
            return tokens.contains(form)
        }
        return haystack.contains(form) || normalizedHaystack.contains(form)
    }

    // MARK: - String helpers

    /// Splits camelCase / PascalCase boundaries into space-separated words, e.g. `useEffect` -> "use effect", `URLSession` -> "url session".
    /// Returns the lowercased, space-joined result; non-letter characters are treated as separators.
    static func deCamelCased(_ text: String) -> String {
        var words: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { words.append(current); current = "" }
        }

        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            let char = Character(scalar)
            if char.isLetter || char.isNumber {
                // Boundary: a lowercase/number followed by an uppercase starts a new word (use|Effect).
                if char.isUppercase, index > 0 {
                    let prev = Character(scalars[index - 1])
                    let next = index + 1 < scalars.count ? Character(scalars[index + 1]) : nil
                    // Start a new word when the previous char was lower/number (useE),
                    // or when an acronym run ends and a new word starts (URLSession -> URL|Session).
                    if prev.isLowercase || prev.isNumber {
                        flush()
                    } else if prev.isUppercase, let next, next.isLowercase {
                        flush()
                    }
                }
                current.append(char)
            } else {
                // Separator (space, hyphen, underscore, punctuation): end the current word.
                flush()
            }
        }
        flush()
        return words.joined(separator: " ").lowercased()
    }

    /// Replaces hyphens / underscores with spaces (e.g. `use-effect` / `use_effect` -> "use effect"), lowercased.
    static func splitSeparators(_ text: String) -> String {
        let replaced = text.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return replaced.lowercased()
    }

    /// The set of lowercase word tokens in the (already lowercased) text. Splits on any non-alphanumeric character.
    private static func tokenSet(of lowercased: String) -> Set<String> {
        let parts = lowercased.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return Set(parts.map(String.init))
    }

    /// Dedupes entries by canonical, keeping the first occurrence (preserves input order).
    private static func dedupedByCanonical(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        var seen = Set<String>()
        var result: [DictionaryEntry] = []
        for entry in entries where seen.insert(entry.canonical).inserted {
            result.append(entry)
        }
        return result
    }
}
