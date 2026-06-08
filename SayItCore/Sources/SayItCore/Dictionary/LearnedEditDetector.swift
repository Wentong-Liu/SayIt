import Foundation

/// A **pure**, stateless detector that inspects an in-place correction the user made to dictated text and decides
/// whether it represents a single learnable word (e.g. a proper noun or code term SayIt misheard / misspelled).
///
/// This is the analysis half of the "learn from edits" feature (Part B of the user dictionary). It does **not** read
/// the UI, persist anything, or know about ``DictionaryStore`` / ``DictionaryEntry`` — the next Part-B PR is responsible
/// for triggering it from a live edit and (if it returns a suggestion) persisting a `DictionaryEntry(source: .learnedFromEdit)`.
/// Keeping the logic pure makes it trivially testable and deterministic.
///
/// Design points:
/// - **Conservative by construction**: it only fires on an *exact single-token substitution* between the injected and the
///   edited text (same word count, exactly one position differs). Anything else — multi-word rewrites, insertions, deletions,
///   identical text — returns `nil`. This avoids learning from large edits that are clearly not "fix one misheard word".
/// - **Proper-noun / uncommon guardrail**: the corrected token must look like something worth learning (a proper noun, an
///   internal-caps code term like `useEffect`, or simply an uncommon word) and must *not* be a high-frequency common English
///   word. So `cat`→`dog` (both common) yields `nil`, while `jon`→`John` yields a suggestion.
/// - **Similarity guardrail**: the heard and corrected tokens must be plausibly the same word (small edit distance). This
///   rejects unrelated single-word swaps that happen to escape the stoplist (`zorp`→`quux`).
public enum LearnedEditDetector {

    /// Inspects an injected/edited string pair and returns the single misheard→corrected word pair worth learning, or `nil`.
    ///
    /// - Parameters:
    ///   - injected: the text SayIt originally produced (dictated/polished).
    ///   - edited: the text after the user's in-place correction.
    /// - Returns: `(heard:, corrected:)` when exactly one token changed and the change passes all guardrails; otherwise `nil`.
    public static func suggestion(injected: String, edited: String) -> (heard: String, corrected: String)? {
        let before = tokenize(injected)
        let after = tokenize(edited)

        // Guardrail 1 — shape: only an exact single-token substitution qualifies.
        // Equal length + exactly one differing index covers all the required cases cleanly:
        //   identical -> 0 diffs -> nil; multi-token edit -> >1 diffs -> nil;
        //   pure insertion/deletion -> length differs -> nil; single substitution -> 1 diff -> candidate.
        guard before.count == after.count, before.count > 0 else { return nil }
        var diffIndex: Int?
        for i in before.indices where before[i] != after[i] {
            if diffIndex != nil { return nil } // more than one differing token -> reject
            diffIndex = i
        }
        guard let index = diffIndex else { return nil } // identical token arrays -> nothing learned

        let heard = before[index]
        let corrected = after[index]
        guard heard != corrected else { return nil }

        // Guardrail 2 — casing-only change: if only the case differs, accept ONLY when the corrected form looks like a
        // proper noun / code term (initial cap or internal caps) AND the lowered word is not a common stop word.
        // This learns `sequoia`→`Sequoia` but rejects sentence-initial capitalisation of a common word (`the`→`The`).
        if heard.lowercased() == corrected.lowercased() {
            if looksLikeProperNoun(corrected) && !isCommonWord(corrected) {
                return (heard: heard, corrected: corrected)
            }
            return nil
        }

        // Guardrail 3 — the corrected token must be proper-noun / uncommon-looking (worth learning).
        guard isUncommonOrProperNoun(corrected) else { return nil }

        // Guardrail 4 — similarity: heard & corrected must be plausibly the same word (small edit distance),
        // rejecting unrelated swaps that slipped past the stoplist.
        guard areSimilar(heard, corrected) else { return nil }

        return (heard: heard, corrected: corrected)
    }

    // MARK: - Tokenization

    /// Characters stripped from the leading/trailing edges of each whitespace token. Internal punctuation is kept so
    /// `useEffect`, `O'Brien`, and `co-founder` survive intact; only surrounding punctuation (`.`, `,`, quotes, parens…) is trimmed.
    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}…")

    /// Splits text into word tokens: split on whitespace, then trim edge punctuation, dropping any empty results.
    /// Deliberately simple/deterministic (no `NLTokenizer`) to keep this function pure, portable, and test-stable.
    static func tokenize(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                String(token).trimmingCharacters(in: edgePunctuation)
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Guardrail heuristics

    /// Whether `word` is a high-frequency common English word (so it is *not* worth learning as a dictionary entry).
    /// The stoplist is intentionally small and lowercased; matching is case-insensitive.
    static func isCommonWord(_ word: String) -> Bool {
        commonWords.contains(word.lowercased())
    }

    /// Whether `word` reads like a proper noun or code identifier: it starts with an uppercase letter, OR it has an
    /// internal uppercase letter (camelCase / `iPhone` / `useEffect`). Purely a casing-shape heuristic.
    static func looksLikeProperNoun(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        if first.isUppercase { return true }
        // Internal caps anywhere after the first character (camelCase, iPhone, useEffect).
        return word.dropFirst().contains { $0.isUppercase }
    }

    /// Whether `word` is worth learning: it looks like a proper noun / code term, OR it is simply not a common word and
    /// is long enough (>= 3 chars) to be a meaningful term rather than a typo of a stop word.
    static func isUncommonOrProperNoun(_ word: String) -> Bool {
        if isCommonWord(word) { return false }
        if looksLikeProperNoun(word) { return true }
        return word.count >= 3
    }

    /// Whether two tokens are plausibly the same word: a casing-only change (distance 0 once lowered) always passes;
    /// otherwise the Levenshtein distance must be small relative to the longer word (<= half its length, at least 1).
    static func areSimilar(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased()
        let lb = b.lowercased()
        if la == lb { return true }
        let distance = levenshtein(la, lb)
        let longer = max(la.count, lb.count)
        let threshold = max(1, longer / 2)
        return distance <= threshold
    }

    /// Classic Levenshtein edit distance (two-row dynamic programming) over Characters.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a)
        let t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }

        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)

        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[t.count]
    }

    // MARK: - Stoplist

    /// A small, documented stoplist of high-frequency common English words. Kept lowercased; intentionally not exhaustive
    /// — its job is only to filter out obvious everyday words (articles, pronouns, prepositions, very common nouns/verbs)
    /// so the detector never "learns" them. Anything outside this list still has to pass the similarity guard to be learned.
    private static let commonWords: Set<String> = [
        // Articles / determiners / conjunctions / prepositions
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "for", "of", "to", "in", "on", "at",
        "by", "with", "from", "as", "into", "onto", "over", "under", "off", "out", "up", "down", "than",
        "then", "if", "else", "when", "while", "because", "about", "above", "below", "between", "through",
        // Pronouns
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them", "my", "your",
        "his", "its", "our", "their", "this", "that", "these", "those", "who", "whom", "which", "what",
        "mine", "yours", "ours", "theirs",
        // Common verbs / auxiliaries
        "is", "am", "are", "was", "were", "be", "been", "being", "do", "does", "did", "have", "has",
        "had", "will", "would", "can", "could", "shall", "should", "may", "might", "must", "go", "goes",
        "went", "gone", "get", "got", "make", "made", "see", "saw", "seen", "say", "said", "run", "ran",
        "come", "came", "take", "took", "give", "gave", "know", "knew", "think", "thought", "want",
        "use", "used", "find", "found", "tell", "told", "ask", "work", "call", "try", "need", "feel",
        "put", "mean", "keep", "let", "begin", "seem", "help", "show", "hear", "play", "move", "live",
        "believe", "bring", "happen", "write", "sit", "stand", "lose", "pay", "meet", "set", "learn",
        "love", "like", "look", "talk", "turn", "start", "stop", "open", "close", "read", "visit",
        // Common nouns
        "cat", "dog", "man", "woman", "boy", "girl", "child", "people", "person", "thing", "way",
        "day", "year", "time", "week", "month", "hour", "world", "life", "hand", "part", "place",
        "case", "point", "fact", "group", "number", "word", "house", "home", "room", "book", "story",
        "money", "water", "food", "car", "road", "city", "town", "name", "side", "kind", "head",
        "eye", "face", "door", "tree", "fish", "bird", "song", "game", "team", "line", "area",
        // Common adjectives / adverbs / misc
        "good", "bad", "big", "small", "large", "little", "long", "short", "high", "low", "old",
        "new", "young", "great", "right", "wrong", "first", "last", "next", "same", "other", "many",
        "much", "more", "most", "less", "least", "few", "some", "any", "all", "no", "not", "yes",
        "now", "here", "there", "very", "too", "also", "just", "only", "even", "still", "well",
        "back", "again", "always", "never", "often", "sometimes", "today", "tomorrow", "yesterday",
        "fast", "slow", "hot", "cold", "warm", "near", "far", "easy", "hard", "true", "false",
        "quick", "brown", "fox", "slow", "lazy",
    ]
}
