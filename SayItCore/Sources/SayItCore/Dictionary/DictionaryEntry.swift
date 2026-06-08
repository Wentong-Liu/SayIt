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

    // MARK: - Tolerant decoding (forward/backward compatible)

    /// The coding keys, declared explicitly so the tolerant ``init(from:)`` and the (still synthesized) `encode(to:)`
    /// agree on the on-disk shape. Names match the synthesized defaults, so existing `dictionary.json` files keep working.
    private enum CodingKeys: String, CodingKey {
        case id, canonical, variants, caseSensitive, enabled, scope, source, createdAt, usageCount
    }

    /// A **tolerant** decoder so one stale/forward-incompatible field never throws away the whole entry (and, in turn,
    /// the whole user dictionary -- see ``DictionaryStore`` lossy load).
    ///
    /// Tolerance rules:
    /// - `id` / `createdAt`: missing -> safe synthesized fallback (`UUID()` / `Date()`) instead of failing.
    ///   These are not user-meaningful enough to justify dropping a recoverable entry.
    /// - `canonical`: **required content** -- a missing or whitespace-only canonical makes the entry meaningless
    ///   (it can never be the replacement target), so we throw `DecodingError.dataCorrupted` and let the lossy array
    ///   load drop just this one entry.
    /// - `variants`: missing -> `[]`.
    /// - `caseSensitive`: missing -> `false`.
    /// - `enabled`: missing -> `true`.
    /// - `scope`: missing -> `.global`.
    /// - `source`: missing **or an unknown rawValue** (e.g. a future source kind on an old build) -> `.manual`.
    /// - `usageCount`: missing -> `0`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        let rawCanonical = try container.decodeIfPresent(String.self, forKey: .canonical) ?? ""
        guard !rawCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No usable canonical -> this entry can never match; mark it droppable for the lossy array load.
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.canonical],
                    debugDescription: "DictionaryEntry has a missing or empty `canonical`; dropping the entry."
                )
            )
        }
        self.canonical = rawCanonical

        self.variants = try container.decodeIfPresent([String].self, forKey: .variants) ?? []
        self.caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.scope = try container.decodeIfPresent(Scope.self, forKey: .scope) ?? .global

        // Unknown / future `source` rawValue -> fall back to `.manual` rather than failing the entry.
        if let rawSource = try container.decodeIfPresent(String.self, forKey: .source) {
            self.source = Source(rawValue: rawSource) ?? .manual
        } else {
            self.source = .manual
        }

        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.usageCount = try container.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
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
