import Foundation

/// The **pure deterministic matcher / rewrite core** of the user dictionary (Layer 3).
///
/// This is the **only** layer in the user dictionary's Part A "three layers" that **guarantees an exact output**: after polish and before injection,
/// it deterministically rewrites segments of the recognized/polished text that hit the dictionary into the canonical form stored by the user (exact case + spacing).
///
/// Design notes (all deliberate, for ease of review):
/// - **Pure function, no I/O, `Sendable`**: carried by an `enum` of static methods, holding no state, never reading disk, never networking.
/// - **Deterministic**: the same input always yields the same output; no `Date()` / randomness / global mutable state.
/// - **Whole-word boundaries**: a hit must land on "non-word character / start-or-end of string" boundaries (word character = letter or digit),
///   so `Cat`->`Dog` will never turn `Caterpillar` into `Dogerpillar`.
/// - **Priority + longest-match-first**: a single left-to-right scan produces **non-overlapping** replacements, arbitrated in the order
///   (1) exact case-sensitive -> (2) exact case-insensitive -> (3) multi-token merge,
///   with a stable tie-break at the same level by "spanning more tokens first" then "entry declaration order".
/// - **Scope filtering, usageCount increment, and Levenshtein / Double Metaphone fuzzy & phonetic matching**
///   are **not in this PR** (to keep determinism; later PRs will introduce them conservatively and opt-in).
///
/// Only ``rewrite(_:using:)`` is exposed externally; ``DictionaryRewriter`` is a thin facade over it.
enum DictionaryMatcher {

    /// Deterministically rewrites the segments of `text` that hit `entries` into their corresponding ``DictionaryEntry/canonical``.
    ///
    /// For an empty dictionary, no enabled entries, or when no segment matches, the input is returned unchanged (identity, zero behavior change).
    /// Surrounding whitespace, punctuation, and unmatched tokens are all preserved byte-for-byte.
    ///
    /// - Parameters:
    ///   - text: the text to rewrite (typically the final post-polish text).
    ///   - entries: the dictionary entries; this method is read-only, never modifies them, never reads disk.
    /// - Returns: the rewritten text; with no match it is exactly identical to the input.
    static func rewrite(_ text: String, using entries: [DictionaryEntry]) -> String {
        let rules = Rule.build(from: entries)
        guard !rules.isEmpty, !text.isEmpty else { return text }

        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        // Upper bound on the multi-token merge window = the maximum token count split out of the rule set's "variants/canonical forms" (capped at 8, to guard against pathologically long entries).
        let maxWindow = min(8, rules.map { $0.maxTokenCount }.max() ?? 1)

        var result = ""
        // The source-string position "consumed" up to last time: used to copy the unmatched original text between tokens back verbatim.
        var cursor = text.startIndex
        var i = 0
        while i < tokens.count {
            // Try from the longest n-gram down to the shortest, taking the first hit (longest-match-first).
            var matched = false
            let maxN = min(maxWindow, tokens.count - i)
            if maxN >= 1 {
                var n = maxN
                while n >= 1 {
                    let span = i...(i + n - 1)
                    if let replacement = matchSpan(tokens: tokens, span: span, in: text, rules: rules) {
                        let startIdx = tokens[i].range.lowerBound
                        let endIdx = tokens[i + n - 1].range.upperBound
                        // Copy back the original text in [cursor, startIdx) (leading whitespace/punctuation).
                        result += text[cursor..<startIdx]
                        result += replacement
                        cursor = endIdx
                        i += n
                        matched = true
                        break
                    }
                    n -= 1
                }
            }
            if !matched {
                i += 1
            }
        }
        // Copy back any remaining trailing original text (everything after the last hit, or the whole string when there was no hit at all).
        result += text[cursor...]
        return result
    }

    // MARK: - Span matching (priority arbitration)

    /// Tries to match the tokens spanned by `span` as a single unit against some rule; on a hit returns its canonical form.
    ///
    /// Arbitration order:
    /// (1) exact case-sensitive ->
    /// (2) exact case-insensitive ->
    /// (3) joined-lowercase canonical, **single-token only** (e.g. `useeffect` -> `useEffect`) ->
    /// (4) explicit-variant multi-token merge (only the user's own `entry.variants` may merge across tokens).
    ///
    /// The deterministic layer deliberately does **not** synthesize multi-word spoken forms from the canonical
    /// spelling: a single-word entry like `iOS` / `macOS` / `OAuth2` therefore never rewrites an ordinary multi-word
    /// phrase such as `i os` / `mac os` / `o auth 2`. Context-aware "spoken phrase -> term" conversion is the LLM's
    /// job (Layer 2 injects the glossary + transcript into the polish prompt). A run-on single token (`useeffect`)
    /// is safe to normalize because it cannot collide with a normal multi-word phrase and is not a common word.
    ///
    /// Multiple tokens (`span` spanning >1 token) may only merge when the separators between them **contain only
    /// whitespace/hyphens**, so an explicit variant `use effect` / `use-effect` can merge while `use. effect` cannot.
    private static func matchSpan(
        tokens: [Token],
        span: ClosedRange<Int>,
        in text: String,
        rules: [Rule]
    ) -> String? {
        let startIdx = tokens[span.lowerBound].range.lowerBound
        let endIdx = tokens[span.upperBound].range.upperBound
        let surface = String(text[startIdx..<endIdx])     // the raw segment including inter-token separators
        let tokenCount = span.count

        // Multiple tokens: the separators must contain only whitespace/hyphens, otherwise it is not a mergeable spoken segment.
        if tokenCount > 1, !separatorsAreMergeable(surface) {
            return nil
        }

        // (1) Exact case-sensitive: surface equals some form byte-for-byte (only effective for that rule's case-sensitive forms).
        for rule in rules {
            if rule.caseSensitive, rule.exactForms.contains(surface) {
                return rule.canonical
            }
        }

        // (2) Exact case-insensitive (only for rules with caseSensitive==false): surface equals some form ignoring case.
        let lowerSurface = surface.lowercased()
        for rule in rules where !rule.caseSensitive {
            if rule.lowercasedExactForms.contains(lowerSurface) {
                return rule.canonical
            }
        }

        // (3) Joined-lowercase canonical, single-token only: a run-on token such as `useeffect` (or an embedded-hyphen
        //     spelling that tokenizes to one word) normalizes to the stored `useEffect`. Restricted to a single token so
        //     it can never merge a multi-word phrase like `use effect` / `i os` into the canonical (over-correction guard).
        let key = normalizedKey(surface)
        guard !key.isEmpty else { return nil }
        if tokenCount == 1 {
            for rule in rules where !rule.caseSensitive {
                if rule.canonicalKey == key {
                    return rule.canonical
                }
            }
        }

        // (4) Explicit-variant multi-token merge: only the user's intentional `entry.variants` may match across the
        //     mergeable span (single or multiple tokens). A learned/confirmed variant like `use effect` is a deliberate
        //     user mapping, so it keeps the merge behavior; the canonical alone never participates here.
        for rule in rules where !rule.caseSensitive {
            if rule.variantKeys.contains(key) {
                return rule.canonical
            }
        }
        return nil
    }

    // MARK: - Tokenization

    /// A word token: a maximal contiguous "letter/digit" segment in the source string and its range.
    private struct Token {
        let range: Range<String.Index>
    }

    /// Splits the text into word tokens (maximal contiguous runs of letters or digits). All other characters (whitespace/punctuation/hyphens) are separators and not part of any token.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            if isWordCharacter(text[idx]) {
                let start = idx
                while idx < text.endIndex, isWordCharacter(text[idx]) {
                    idx = text.index(after: idx)
                }
                tokens.append(Token(range: start..<idx))
            } else {
                idx = text.index(after: idx)
            }
        }
        return tokens
    }

    /// Word character = letter or digit (Unicode-friendly). Everything else (whitespace, punctuation, hyphens, etc.) is a boundary/separator.
    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// Whether the inter-token separators inside a segment are "mergeable": after removing all letters/digits, the remaining characters may only be whitespace or hyphens.
    /// Used as the multi-token merge gate: `use effect` / `use-effect` can merge; `use. effect` / `use_effect` cannot.
    private static func separatorsAreMergeable(_ surface: String) -> Bool {
        for c in surface where !isWordCharacter(c) {
            if c.isWhitespace { continue }
            if c == "-" || c == "\u{2010}" { continue }  // ASCII hyphen + Unicode hyphen
            return false
        }
        return true
    }

    /// Normalized key: lowercased + all whitespace and hyphens removed. `use effect` / `use-effect` / `UseEffect` share the same key.
    private static func normalizedKey(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s.lowercased() {
            if c.isWhitespace || c == "-" || c == "\u{2010}" { continue }
            out.append(c)
        }
        return out
    }

    // MARK: - Rules

    /// A matching rule pre-compiled from one ``DictionaryEntry`` (read-only, reusable).
    ///
    /// The deterministic Layer 3 deliberately does **not** synthesize multi-word spoken forms from the canonical
    /// spelling (that was T55's `derivedSpokenForms`, which over-corrected ordinary text — `iOS` rewriting `i os`).
    /// A single-word entry therefore matches its canonical only via exact / case-insensitive / joined-lowercase
    /// (single token); context-aware "spoken phrase -> term" conversion is the LLM's job (Layer 2). Only the user's
    /// explicit ``DictionaryEntry/variants`` may merge across multiple tokens, because those are deliberate mappings.
    struct Rule {
        let canonical: String
        let caseSensitive: Bool
        /// The full raw set of "recognizable forms" (explicit variants + the canonical form itself), preserving case -- for exact case-sensitive comparison.
        let exactForms: Set<String>
        /// The lowercased set of the above forms -- for exact case-insensitive comparison.
        let lowercasedExactForms: Set<String>
        /// The normalized key (lowercased + whitespace/hyphens removed) of the **canonical only** -- matched against a
        /// **single-token** surface so a run-on `useeffect` -> `useEffect`, while a multi-word phrase never collides.
        let canonicalKey: String
        /// The normalized-key set of the **explicit variants only** -- these are intentional user mappings and keep the
        /// multi-token merge behavior (e.g. a learned variant `use effect` rewrites the two-word span `use effect`).
        let variantKeys: Set<String>
        /// The maximum token count of any form when split on whitespace/hyphens -- determines the multi-token merge window size.
        let maxTokenCount: Int

        /// Builds the rule set from the entry list: drops `!enabled` entries, and entries whose canonical and variants are all whitespace.
        static func build(from entries: [DictionaryEntry]) -> [Rule] {
            var rules: [Rule] = []
            for entry in entries where entry.enabled {
                let canonical = entry.canonical
                guard !canonical.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                // Explicit user variants only (no auto-derived spoken forms); pure-whitespace ones are dropped.
                let cleanedVariants = entry.variants.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

                // Recognizable forms for the exact / case-insensitive layers = each explicit variant + the canonical
                // itself (the canonical is also a spoken form that should be preserved/normalized).
                var forms = cleanedVariants
                forms.append(canonical)

                let exact = Set(forms)
                let lowered = Set(forms.map { $0.lowercased() })
                // The canonical's joined-lowercase key powers the single-token run-on normalization (e.g. `useeffect`).
                let canonicalKey = normalizedKey(canonical)
                // Variant keys keep the multi-token merge; they are intentional user mappings.
                let variantKeys = Set(cleanedVariants.map { normalizedKey($0) }.filter { !$0.isEmpty })
                // The merge window is driven by the explicit variants (the canonical never merges across tokens);
                // a single token always works, so the floor is 1.
                let maxTokens = cleanedVariants.map { tokenCount(of: $0) }.max() ?? 1
                rules.append(Rule(
                    canonical: canonical,
                    caseSensitive: entry.caseSensitive,
                    exactForms: exact,
                    lowercasedExactForms: lowered,
                    canonicalKey: canonicalKey,
                    variantKeys: variantKeys,
                    maxTokenCount: max(1, maxTokens)
                ))
            }
            return rules
        }

        /// The token count of a form when split into "letter/digit segments" (same convention as ``tokenize(_:)``).
        private static func tokenCount(of form: String) -> Int {
            var count = 0
            var inWord = false
            for c in form {
                if isWordCharacter(c) {
                    if !inWord { count += 1; inWord = true }
                } else {
                    inWord = false
                }
            }
            return count
        }
    }
}
