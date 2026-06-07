import Foundation
import Observation
import SayItCore

/// The view model for the "Dictionary" settings pane: bridges the `actor`-isolated ``DictionaryStore`` (async)
/// into a main-actor, SwiftUI-bindable mirror so the list re-renders the moment entries change.
///
/// Design points (mirrors the PR #18 stored-`@Observable`-mirror pattern of ``SettingsViewModel``):
/// - **Stored mirror**: ``entries`` is a plain stored property the view binds to. Because the store is an
///   `actor`, we cannot read it synchronously inside `body`; instead every CRUD op drives the actor and then
///   re-pulls `all()` into this mirror. The mirror assignment is what `@Observable` tracks to invalidate the view.
/// - **Live updates**: registers for ``DictionaryStore/didChangeNotification`` (object is `nil` per the store
///   contract) and re-reads `all()` on receipt — so any change, even from another code path (e.g. the
///   dictation pipeline), refreshes the list.
/// - **Injectable**: `store` / `notificationCenter` are injectable so unit tests pass a temp-directory store and an
///   isolated notification center (exactly like ``DictionaryStoreTests``), never touching real user data.
/// - **Strictly additive**: does not touch ``DictationCoordinator`` / transcribers / `PolishPromptBuilder`. PR-2's
///   ``DictionaryRewriter`` already reads `store.all()` after polish, so feeding entries through the store here makes
///   dictation rewriting work with no pipeline change.
@MainActor
@Observable
final class DictionaryViewModel {
    /// The user-dictionary store (the `actor` from PR-1). Not observable: reads/writes go through `await`.
    @ObservationIgnored private let store: DictionaryStore

    /// The change-notification center; defaults to `.default`, unit tests pass an isolated instance.
    @ObservationIgnored private let notificationCenter: NotificationCenter

    /// The live-update observer token; removed on `stopObserving()` / `deinit`.
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// The main-actor mirror of the store's entries that SwiftUI binds to. Kept in store/persistence order.
    private(set) var entries: [DictionaryEntry] = []

    /// - Parameters:
    ///   - store: the injected dictionary store; defaults to a fresh ``DictionaryStore`` (which points at the same
    ///     default `dictionary.json` the dictation pipeline reads), unit tests pass a temp-directory store.
    ///   - notificationCenter: the change-notification center; defaults to `.default`.
    init(store: DictionaryStore = DictionaryStore(), notificationCenter: NotificationCenter = .default) {
        self.store = store
        self.notificationCenter = notificationCenter
    }

    // Note: no `deinit` cleanup of `observer` — Swift 6 forbids touching a non-`Sendable` token from a nonisolated
    // deinit. The view reliably calls `stopObserving()` on `.onDisappear`, and the observer closure captures `self`
    // weakly (so it no-ops and creates no retain cycle even if removal is missed).

    // MARK: - Load / observe

    /// Re-pulls all entries from the store into the ``entries`` mirror. Called on appear and on every change.
    func reload() async {
        entries = await store.all()
    }

    /// Starts observing ``DictionaryStore/didChangeNotification`` so the list updates live on any store change.
    /// Idempotent: a second call is a no-op while already observing.
    func startObserving() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: DictionaryStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The store's notification carries no payload (object is nil); re-read via all().
            Task { @MainActor in await self?.reload() }
        }
    }

    /// Stops observing change notifications. Called on disappear.
    func stopObserving() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    // MARK: - CRUD (drive the actor, then refresh the mirror immediately)

    /// Adds a new manual / global entry, then refreshes the mirror (so the UI updates even before the
    /// notification round-trips). Variants are sanitized (trimmed, deduped, canonical-equal/empty dropped).
    ///
    /// In the single-word UI the editor calls `add(canonical:)` only — `variants` default to `[]` (the matcher
    /// auto-derives spoken forms from the canonical), `caseSensitive` to `false`, and `enabled` to `true`. The
    /// remaining parameters stay for callers / tests that still supply explicit variants.
    func add(canonical: String, variants: [String] = [], caseSensitive: Bool = false, enabled: Bool = true) async {
        let trimmedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCanonical.isEmpty else { return }
        let entry = DictionaryEntry(
            canonical: trimmedCanonical,
            variants: Self.sanitize(variants, canonical: trimmedCanonical),
            caseSensitive: caseSensitive,
            enabled: enabled,
            scope: .global,
            source: .manual
        )
        await store.add(entry)
        await reload()
    }

    /// Updates an existing entry wholesale (id / createdAt / usageCount are preserved by the caller building a
    /// mutated copy of the original entry), then refreshes the mirror.
    func update(_ entry: DictionaryEntry) async {
        await store.update(entry)
        await reload()
    }

    /// Removes an entry by id, then refreshes the mirror.
    func remove(id: UUID) async {
        await store.remove(id: id)
        await reload()
    }

    /// Convenience for the per-row toggle: builds a mutated copy with the new `enabled` flag and writes it through.
    func setEnabled(_ enabled: Bool, for entry: DictionaryEntry) async {
        guard entry.enabled != enabled else { return }
        var copy = entry
        copy.enabled = enabled
        await update(copy)
    }

    // MARK: - Helpers

    /// Normalizes raw variant input: trims each, drops empties, drops any equal to `canonical`, and de-dups
    /// while preserving first-seen order. Pure (static) so it is trivially unit-tested.
    ///
    /// Case-equal-to-canonical entries are dropped case-sensitively (we only drop exact duplicates of the canonical
    /// spelling, leaving differently-cased forms as legitimate heard-forms the rewriter can correct).
    ///
    /// `nonisolated` so the editor sheet (a non-main-actor value type) can normalize variants synchronously.
    nonisolated static func sanitize(_ raw: [String], canonical: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed != canonical else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}
