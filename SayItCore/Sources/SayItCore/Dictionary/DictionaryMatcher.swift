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
    /// Arbitration order: (1) exact case-sensitive -> (2) exact case-insensitive -> (3) multi-token merge.
    /// Multiple tokens (`span` spanning >1 token) may only merge when the separators between them **contain only whitespace/hyphens**,
    /// so `use effect` / `use-effect` can merge while `use. effect` cannot.
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

        // (1) Exact case-sensitive: surface equals some variant byte-for-byte (only effective for that rule's case-sensitive forms).
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

        // (3) Multi-token merge: the normalized key (lowercased + stripped of whitespace/hyphens) is equal.
        //     A single token also goes through this step to cover cases like "embedded hyphen" (e.g. `use-effect` split into two tokens).
        let key = normalizedKey(surface)
        guard !key.isEmpty else { return nil }
        for rule in rules where !rule.caseSensitive {
            if rule.normalizedKeys.contains(key) {
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
    /// `internal` (not `private`) so the pure ``derivedSpokenForms(from:)`` helper is unit-testable via
    /// `@testable import`; the rest of its surface is incidental and only consumed by ``DictionaryMatcher``.
    struct Rule {
        let canonical: String
        let caseSensitive: Bool
        /// The full raw set of "recognizable forms" (variants + the canonical form itself), preserving case -- for exact case-sensitive comparison.
        let exactForms: Set<String>
        /// The lowercased set of the above forms -- for exact case-insensitive comparison.
        let lowercasedExactForms: Set<String>
        /// The normalized-key set of the above forms (lowercased + whitespace/hyphens removed) -- for multi-token merge comparison.
        let normalizedKeys: Set<String>
        /// The maximum token count of any form when split on whitespace/hyphens -- determines the multi-token merge window size.
        let maxTokenCount: Int

        /// Builds the rule set from the entry list: drops `!enabled` entries, and entries whose canonical and variants are all whitespace.
        static func build(from entries: [DictionaryEntry]) -> [Rule] {
            var rules: [Rule] = []
            for entry in entries where entry.enabled {
                let canonical = entry.canonical
                // Recognizable forms = each variant + the canonical form itself (the canonical form is itself a spoken form that can be recognized and preserved/normalized).
                var forms = entry.variants
                forms.append(canonical)
                // Auto-derive likely spoken/misheard forms from the canonical spelling, so the deterministic
                // replacement still works when the user supplied no variants (the single-word/Typeless model):
                // a typed "useEffect" gains "use effect" / "use-effect" / "useeffect" without any user input.
                // These are additive and de-duped by the Set construction below; for a plain/Chinese/all-caps
                // term `derivedSpokenForms` returns [] (over-correction guard), leaving exact matching as-is.
                //
                // Skipped for caseSensitive entries: derived forms are lowercase and would land in `exactForms`,
                // where the case-sensitive layer matches byte-for-byte — that would defeat the user's strict-case
                // choice (e.g. an `iOS`/caseSensitive entry must not match a lowercase "ios"). A caseSensitive entry
                // therefore matches only its own user-supplied forms.
                if !entry.caseSensitive {
                    forms.append(contentsOf: derivedSpokenForms(from: canonical))
                }
                // Drop pure-whitespace forms.
                let cleaned = forms.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !cleaned.isEmpty,
                      !canonical.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                let exact = Set(cleaned)
                let lowered = Set(cleaned.map { $0.lowercased() })
                let keys = Set(cleaned.map { normalizedKey($0) }.filter { !$0.isEmpty })
                let maxTokens = cleaned.map { tokenCount(of: $0) }.max() ?? 1
                rules.append(Rule(
                    canonical: canonical,
                    caseSensitive: entry.caseSensitive,
                    exactForms: exact,
                    lowercasedExactForms: lowered,
                    normalizedKeys: keys,
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

        /// Derives the likely spoken / misheard forms of a canonical term so the deterministic Layer-3 matcher can
        /// normalize them back to the canonical even when the user supplied **no** variants (the single-word model).
        ///
        /// The canonical is split into segments on internal boundaries:
        /// - existing whitespace / hyphens (so a typed `"feature flag"` yields `[feature, flag]`),
        /// - lower→upper case boundaries (`useEffect` → `use|Effect`; `bigQuery` → `big|Query`),
        /// - acronym→word boundaries: a run of uppercase letters followed by an upper+lower pair splits before that
        ///   last uppercase (`HTTPServer` → `HTTP|Server`),
        /// - letter↔digit boundaries (`PT1` → `PT|1`), matching the `PT时间` spirit.
        ///
        /// When the split produces a single segment — a plain word (`codex`), an all-caps token (`GPT`), or a
        /// non-cased / CJK term (`拓荆科技`) — this returns `[]`: case-insensitive exact matching already covers those,
        /// and we must not fabricate spoken variants for them (the over-correction guard).
        ///
        /// From two or more lowercased segments it builds the space-joined, hyphen-joined, and run-on lowercase forms
        /// (e.g. `"use effect"`, `"use-effect"`, `"useeffect"`), de-duped, with any form equal (case-insensitively) to
        /// the canonical or empty dropped. Pure and order-stable, so determinism is preserved. Derived forms are
        /// lowercase and only ever consulted by the case-INSENSITIVE matching layers, so they are inert for a
        /// `caseSensitive` entry (which correctly stays strict-case).
        static func derivedSpokenForms(from canonical: String) -> [String] {
            let segments = caseAwareSegments(of: canonical)
            // One segment (or none): plain word / all-caps / CJK / non-cased term — exact handles it; do not fabricate.
            guard segments.count >= 2 else { return [] }

            let lowered = segments.map { $0.lowercased() }
            let spaceJoined = lowered.joined(separator: " ")
            let hyphenJoined = lowered.joined(separator: "-")
            let runOn = lowered.joined()

            var seen = Set<String>()
            var result: [String] = []
            for form in [spaceJoined, hyphenJoined, runOn] {
                guard !form.isEmpty else { continue }
                // Drop a form that is byte-for-byte the canonical itself (the canonical is already a form); a
                // lowercased run-on like "useeffect" is kept on purpose — it documents intent and is inert (the
                // canonical's own lowercased spelling already covers it via the case-insensitive layer).
                guard form != canonical else { continue }
                guard !seen.contains(form) else { continue }
                seen.insert(form)
                result.append(form)
            }
            return result
        }

        /// Splits a term into segments on whitespace/hyphens **and** internal case / script boundaries.
        ///
        /// Boundaries (a new segment starts at the character after the boundary):
        /// - any whitespace or hyphen acts as a separator (consumed, not part of a segment),
        /// - lower→upper (`useEffect`),
        /// - upper-run→word: `XMLParser`-style — break before the last uppercase of an uppercase run when the next
        ///   character is lowercase, so `HTTPServer` → `HTTP` + `Server`,
        /// - letter↔digit in either direction (`PT1` → `PT` + `1`).
        ///
        /// Returns only non-empty segments. A term with no internal boundary yields a single segment.
        private static func caseAwareSegments(of term: String) -> [String] {
            let chars = Array(term)
            guard !chars.isEmpty else { return [] }

            var segments: [String] = []
            var current = ""

            func isSeparator(_ c: Character) -> Bool {
                c.isWhitespace || c == "-" || c == "\u{2010}"
            }

            for index in chars.indices {
                let c = chars[index]
                if isSeparator(c) {
                    if !current.isEmpty { segments.append(current); current = "" }
                    continue
                }
                if current.isEmpty {
                    current.append(c)
                    continue
                }
                let prev = chars[index - 1]
                var boundary = false
                // lower → upper (useEffect, bigQuery)
                if prev.isLowercase, c.isUppercase {
                    boundary = true
                }
                // upper-run → word: prev is uppercase, current is uppercase, next is lowercase (HTTPServer -> HTTP|Server)
                else if prev.isUppercase, c.isUppercase,
                        index + 1 < chars.count, chars[index + 1].isLowercase {
                    boundary = true
                }
                // letter ↔ digit, either direction (PT1 -> PT|1; 1x -> 1|x)
                else if (prev.isLetter && c.isNumber) || (prev.isNumber && c.isLetter) {
                    boundary = true
                }
                if boundary {
                    segments.append(current)
                    current = ""
                }
                current.append(c)
            }
            if !current.isEmpty { segments.append(current) }
            return segments
        }
    }
}
