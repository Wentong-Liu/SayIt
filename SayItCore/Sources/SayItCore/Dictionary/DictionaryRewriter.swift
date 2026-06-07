import Foundation

/// The **public facade** of the user-dictionary Layer 3: deterministically rewrites segments of the post-polish text that hit the dictionary into their canonical form.
///
/// This is the public API wired into the pipeline: called once **after** ``PolishPipeline/polish(_:context:style:provider:polishEnabled:)``
/// and **before** ``TextInjector/inject(_:)`` (see `DictationCoordinator`).
///
/// Behavior contract:
/// - **Pure function, deterministic, whole-word boundaries**: the actual matching/rewriting is delegated to ``DictionaryMatcher``; this type is only a thin wrapper.
/// - **Empty / irrelevant entries -> identity**: for an empty dictionary, no enabled entries, or no matched segment, the input is returned unchanged;
///   surrounding whitespace, punctuation, and unmatched text are preserved byte-for-byte. An empty dictionary means "zero behavior change".
public enum DictionaryRewriter {

    /// Uses `entries` to rewrite the matched segments of `text` into their respective ``DictionaryEntry/canonical`` forms.
    ///
    /// - Parameters:
    ///   - text: the text to rewrite (typically the final post-polish text).
    ///   - entries: the dictionary entries; read-only, never modified, never read from disk, never networked.
    /// - Returns: the rewritten text; for an empty dictionary / no match it is exactly identical to the input (identity).
    public static func apply(to text: String, using entries: [DictionaryEntry]) -> String {
        guard !entries.isEmpty else { return text }
        return DictionaryMatcher.rewrite(text, using: entries)
    }
}
