import Foundation
import os

/// Persistent storage for the user dictionary (foundation layer, **not hooked into the pipeline, no matching logic**).
///
/// Responsibility: persists ``UserDictionary`` as JSON to `Application Support/SayIt/dictionary.json`,
/// loading it once into the in-memory cache on first access, then **atomically writing to disk** and posting a **change notification** on each add/update/remove.
///
/// Design points:
/// - **`actor`**: disk read/write serialized, all CRUD goes through actor isolation and is naturally concurrency-safe (the first public actor that posts notifications).
/// - **App Support directory reuse**: the default root directory uses the same resolution as ``ModelManager/downloadBase``
///   (`Application Support/SayIt`, falling back to `Caches/SayIt` when unavailable), sharing a root with the model cache, not establishing a separate directory scheme.
/// - **Injectable**: `baseDirectory` / `fileName` / `notificationCenter` / `fileManager` are all injectable,
///   unit tests pass a temp directory and an isolated notification center, never touching real user data.
/// - **Change notification**: mirrors ``AppConfig/didChangeNotification``'s naming and "only post when the value actually changes" semantics;
///   posts ``DictionaryStore/didChangeNotification`` after each CRUD that truly changes state succeeds.
///   `object` is `nil` (an `actor` instance is not `Sendable` and cannot be a notification object; listeners re-read with ``all()`` on receipt).
/// - **Never crashes**: starts with an empty dictionary silently when the file is missing or decoding fails (logs then continues), a write failure only logs without throwing --
///   the foundation layer must not propagate I/O errors to the caller.
public actor DictionaryStore {
    /// The notification posted when the dictionary changes. Mirrors ``AppConfig/didChangeNotification``'s naming style.
    ///
    /// Posted after each CRUD that truly changes the dictionary (add / update / remove / replaceAll) succeeds.
    /// `object` is `nil` (an `actor` cannot be a notification object); listeners call ``all()`` on receipt to re-read the latest content.
    public static let didChangeNotification = Notification.Name("com.liuwentong.SayIt.DictionaryStoreDidChange")

    /// The default dictionary root directory: `Application Support/SayIt` (same root as ``ModelManager/downloadBase``).
    ///
    /// Resolved the same way as ``ModelManager``: take Application Support (created if missing), fall back to Caches on failure,
    /// always avoiding the TCC-protected `~/Documents`. The dictionary file lands as `dictionary.json` under this directory.
    nonisolated public static let defaultBaseDirectory: URL = {
        let fm = FileManager.default
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport.appending(component: "SayIt")
        }
        // In the extreme case Application Support cannot be obtained: fall back to the cache directory, still avoiding the TCC-protected Documents.
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appending(component: "SayIt")
    }()

    private let baseDirectory: URL
    private let fileURL: URL
    private let notificationCenter: NotificationCenter
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.liuwentong.SayIt", category: "dictionary")

    /// The in-memory cache; `nil` means it has not yet been loaded from disk (lazy-loaded once).
    private var cache: UserDictionary?

    /// - Parameters:
    ///   - baseDirectory: the directory the dictionary file lives in; defaults to ``defaultBaseDirectory``, unit tests pass a temp directory.
    ///   - fileName: the dictionary file name; defaults to `"dictionary.json"`.
    ///   - notificationCenter: the change-notification center; defaults to `.default`, unit tests can pass an isolated instance to observe.
    ///   - fileManager: the file system handle; defaults to `.default`.
    public init(
        baseDirectory: URL = DictionaryStore.defaultBaseDirectory,
        fileName: String = "dictionary.json",
        notificationCenter: NotificationCenter = .default,
        fileManager: FileManager = .default
    ) {
        self.baseDirectory = baseDirectory
        self.fileURL = baseDirectory.appending(component: fileName)
        self.notificationCenter = notificationCenter
        self.fileManager = fileManager
    }

    // MARK: - CRUD

    /// Returns all current entries (loading from disk first if necessary).
    public func all() -> [DictionaryEntry] {
        ensureLoaded().entries
    }

    /// Appends an entry; then writes to disk and posts a change notification.
    public func add(_ entry: DictionaryEntry) {
        var dict = ensureLoaded()
        dict.entries.append(entry)
        commit(dict)
    }

    /// Replaces an existing entry by `id`; only writes to disk + posts a notification when found **and the content actually changes**.
    public func update(_ entry: DictionaryEntry) {
        var dict = ensureLoaded()
        guard let index = dict.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        guard dict.entries[index] != entry else { return }
        dict.entries[index] = entry
        commit(dict)
    }

    /// Removes an entry by `id`; only writes to disk + posts a notification when a removal actually happens.
    public func remove(id: UUID) {
        var dict = ensureLoaded()
        let before = dict.entries.count
        dict.entries.removeAll { $0.id == id }
        guard dict.entries.count != before else { return }
        commit(dict)
    }

    /// Replaces the dictionary wholesale with the given entries; writes to disk and posts a change notification (unconditionally treated as one change).
    public func replaceAll(_ entries: [DictionaryEntry]) {
        // ensureLoaded() first to guarantee the base directory has been created (it is the only place that creates the directory); otherwise when replaceAll is
        // the first operation on a fresh store, a missing directory would cause the atomic write to fail, leaving the data only in memory and silently lost.
        ensureLoaded()
        commit(UserDictionary(entries: entries))
    }

    // MARK: - Load / write / notify

    /// Lazy-load once: on first access, create the directory and read+decode from disk; if the file is missing or corrupt, start with an empty dictionary (logs, never throws/crashes).
    @discardableResult
    private func ensureLoaded() -> UserDictionary {
        if let cache { return cache }

        // Ensure the directory exists, so the subsequent atomic write can land directly.
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            // File missing (first run): start with an empty dictionary.
            let empty = UserDictionary()
            cache = empty
            return empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(UserDictionary.self, from: data)
            cache = decoded
            return decoded
        } catch {
            // File corrupt/undecodable: log and start with an empty dictionary, never crashing.
            logger.error("Failed to load dictionary at \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public). Starting empty.")
            let empty = UserDictionary()
            cache = empty
            return empty
        }
    }

    /// Update the in-memory cache -> atomic disk write -> post a change notification. A write failure only logs, does not throw.
    private func commit(_ dict: UserDictionary) {
        cache = dict
        persist(dict)
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }

    /// Atomic disk write: `.atomic` writes a temp file first then renames, so no half-written/corrupt file is ever left on disk.
    ///
    /// `JSONEncoder` uses `.sortedKeys + .prettyPrinted` to output stable, diffable JSON;
    /// date encoding uses the default `.deferredToDate`, consistent with the decoding default. A failure only logs, not contaminating the caller.
    private func persist(_ dict: UserDictionary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(dict)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Failed to persist dictionary to \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public).")
        }
    }
}
