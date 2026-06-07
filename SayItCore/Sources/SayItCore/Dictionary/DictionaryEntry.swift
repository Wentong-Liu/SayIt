import Foundation

/// A single entry in the user dictionary (the data model for a replacement/correction rule).
///
/// This is the **foundation data layer** of the user dictionary feature: it only describes the fact of "one canonical spelling + its several variants",
/// without any matching/rewriting logic (the matcher, rewriter, and STT/polish biasing are introduced in later PRs).
///
/// Design points:
/// - **`Codable`**: persisted directly as JSON (see ``DictionaryStore``), with stable, evolvable field semantics.
/// - **`Identifiable`**: uses `id` (`UUID`) as a stable identifier, supporting update/delete by id and UI list diffing.
/// - **`Sendable`**: can safely cross actor boundaries (held by the ``DictionaryStore`` `actor`).
/// - **`Equatable`**: reused for Codable round-trip equality assertions in unit tests and for UI diffing.
public struct DictionaryEntry: Codable, Identifiable, Sendable, Equatable {
    /// The entry's stable unique identifier; used for update/delete by id, kept unchanged across persistence.
    public let id: UUID

    /// The canonical spelling (the target text to replace with on a hit, e.g. the standard spelling of a brand name/term).
    public var canonical: String

    /// Variant spellings that will be corrected to `canonical` (e.g. homophone misspellings, colloquial spellings).
    public var variants: [String]

    /// Whether matching is case-sensitive. Defaults to `false` (case is irrelevant in most scenarios).
    public var caseSensitive: Bool

    /// Whether this entry is enabled. Defaults to `true`; when set to `false`, the data is kept but does not participate in matching.
    public var enabled: Bool

    /// The scope: global or limited to a specific app.
    public var scope: Scope

    /// The source: manually added by the user / learned from one edit.
    public var source: Source

    /// The creation time; used for sorting and displays such as "recently added".
    public var createdAt: Date

    /// The cumulative number of times it was hit and applied; used for sorting/cleaning up low-frequency entries. Defaults to `0`.
    public var usageCount: Int

    /// The entry's scope.
    ///
    /// `app(bundleID:)` carries an associated value, and Swift auto-synthesizes its `Codable` implementation (encoded as a form with
    /// an associated value), no need to hand-write `CodingKeys`/`init(from:)`. Both cases are covered by round-trip unit tests.
    public enum Scope: Codable, Sendable, Equatable {
        /// Effective in all apps.
        case global
        /// Effective only in the app with the specified bundle id.
        case app(bundleID: String)
    }

    /// The entry's source. Persists a `rawValue` string, for human readability and backward compatibility.
    public enum Source: String, Codable, Sendable {
        /// Manually added by the user in the management UI.
        case manual
        /// Learned from the user's edit of one output result (used in later PRs).
        case learnedFromEdit
    }

    /// A memberwise initializer with sensible defaults: creating a "manual / global" entry only needs `canonical` (+ optional `variants`).
    ///
    /// - Note: `createdAt` defaults to `Date()` (i.e. "created now"), which is appropriate for real creation;
    ///   unit tests doing equality assertions should explicitly pass a fixed `Date` to guarantee determinism.
    public init(
        id: UUID = UUID(),
        canonical: String,
        variants: [String] = [],
        caseSensitive: Bool = false,
        enabled: Bool = true,
        scope: Scope = .global,
        source: Source = .manual,
        createdAt: Date = Date(),
        usageCount: Int = 0
    ) {
        self.id = id
        self.canonical = canonical
        self.variants = variants
        self.caseSensitive = caseSensitive
        self.enabled = enabled
        self.scope = scope
        self.source = source
        self.createdAt = createdAt
        self.usageCount = usageCount
    }
}

/// The root container of the user dictionary (the whole dictionary = a set of entries). Persisted directly as the top-level structure of the JSON file.
public struct UserDictionary: Codable, Sendable, Equatable {
    /// All entries; the order is the persistence/display order.
    public var entries: [DictionaryEntry]

    /// - Parameter entries: the initial entries; defaults to an empty dictionary.
    public init(entries: [DictionaryEntry] = []) {
        self.entries = entries
    }
}
