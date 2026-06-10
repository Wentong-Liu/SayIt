import XCTest
@testable import SayItCore

/// Codable round-trip unit test for DictionaryEntry / UserDictionary (deterministic: fixed UUID + fixed Date).
final class DictionaryEntryCodableTests: XCTestCase {

    /// A fixed time, sidestepping the indeterminacy from the `Date()` default, making equality assertions repeatable.
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testGlobalScopeEntryRoundTrips() throws {
        let entry = DictionaryEntry(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            canonical: "SayIt",
            variants: ["say it", "sayit"],
            caseSensitive: true,
            enabled: true,
            scope: .global,
            source: .manual,
            createdAt: fixedDate,
            usageCount: 3
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DictionaryEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.scope, .global)
    }

    func testAppScopeEntryRoundTrips() throws {
        let entry = DictionaryEntry(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            canonical: "Xcode",
            variants: ["x code"],
            scope: .app(bundleID: "com.apple.dt.Xcode"),
            source: .learnedFromEdit,
            createdAt: fixedDate,
            usageCount: 0
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DictionaryEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.scope, .app(bundleID: "com.apple.dt.Xcode"))
        XCTAssertEqual(decoded.source, .learnedFromEdit)
    }

    func testMemberwiseInitDefaults() {
        // Just passing canonical (+variants) creates a "manual / global / enabled / case-insensitive" entry.
        let entry = DictionaryEntry(canonical: "GPT", variants: ["gpt"])
        XCTAssertEqual(entry.canonical, "GPT")
        XCTAssertEqual(entry.variants, ["gpt"])
        XCTAssertFalse(entry.caseSensitive)
        XCTAssertTrue(entry.enabled)
        XCTAssertEqual(entry.scope, .global)
        XCTAssertEqual(entry.source, .manual)
        XCTAssertEqual(entry.usageCount, 0)
    }

    func testUserDictionaryRoundTrips() throws {
        let dict = UserDictionary(entries: [
            DictionaryEntry(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                canonical: "A", variants: ["a"], scope: .global, createdAt: fixedDate
            ),
            DictionaryEntry(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                canonical: "B", variants: [], scope: .app(bundleID: "com.b"), createdAt: fixedDate
            ),
        ])
        let data = try JSONEncoder().encode(dict)
        let decoded = try JSONDecoder().decode(UserDictionary.self, from: data)
        XCTAssertEqual(decoded, dict)
    }

    func testEmptyUserDictionaryRoundTrips() throws {
        let dict = UserDictionary()
        let data = try JSONEncoder().encode(dict)
        let decoded = try JSONDecoder().decode(UserDictionary.self, from: data)
        XCTAssertEqual(decoded, dict)
        XCTAssertTrue(decoded.entries.isEmpty)
    }
}

/// DictionaryStore persistence + change-notification unit test: all through an injected temp directory, never touching the real dictionary.
final class DictionaryStoreTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Each case has an independent temp root directory; tearDown cleans up (mirroring ModelManagerTests' makeTempDir style).
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appending(component: "sayit-dictstore-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    private func makeStore(notificationCenter: NotificationCenter = .default) -> DictionaryStore {
        DictionaryStore(baseDirectory: tempDir, notificationCenter: notificationCenter)
    }

    private func sampleEntry(canonical: String = "SayIt") -> DictionaryEntry {
        DictionaryEntry(
            id: UUID(),
            canonical: canonical,
            variants: ["say it"],
            scope: .global,
            createdAt: fixedDate
        )
    }

    /// Reads dictionary.json directly from disk and decodes it, proving that what the atomic write leaves behind is legal JSON.
    private func decodeOnDisk() throws -> UserDictionary {
        let fileURL = tempDir.appending(component: "dictionary.json")
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(UserDictionary.self, from: data)
    }

    // MARK: - Persistence round-trip (a fresh store re-reads from disk)

    func testAddPersistsAcrossFreshStore() async throws {
        let entry = sampleEntry()
        let store1 = makeStore()
        await store1.add(entry)

        // A fresh store pointing at the same temp directory: the content read must come from disk (not memory).
        let store2 = makeStore()
        let loaded = await store2.all()
        XCTAssertEqual(loaded, [entry])

        // The on-disk file exists and is legal JSON.
        let onDisk = try decodeOnDisk()
        XCTAssertEqual(onDisk.entries, [entry])
    }

    func testUpdatePersists() async throws {
        var entry = sampleEntry()
        let store = makeStore()
        await store.add(entry)

        entry.canonical = "SayItRenamed"
        entry.usageCount = 7
        await store.update(entry)

        let reloaded = await makeStore().all()
        XCTAssertEqual(reloaded, [entry])
        let onDisk = try decodeOnDisk().entries
        XCTAssertEqual(onDisk, [entry])
    }

    func testUpdateUnknownIdIsNoop() async throws {
        let entry = sampleEntry()
        let store = makeStore()
        await store.add(entry)

        // An id not in the dictionary: update should not change anything.
        let stranger = sampleEntry(canonical: "Other")
        await store.update(stranger)

        let after = await store.all()
        XCTAssertEqual(after, [entry])
    }

    func testRemovePersists() async throws {
        let entry = sampleEntry()
        let store = makeStore()
        await store.add(entry)
        await store.remove(id: entry.id)

        let reloaded = await makeStore().all()
        XCTAssertTrue(reloaded.isEmpty)
        XCTAssertTrue(try decodeOnDisk().entries.isEmpty)
    }

    func testReplaceAllPersists() async throws {
        let store = makeStore()
        await store.add(sampleEntry(canonical: "Old"))

        let replacement = [sampleEntry(canonical: "New1"), sampleEntry(canonical: "New2")]
        await store.replaceAll(replacement)

        let reloaded = await makeStore().all()
        XCTAssertEqual(reloaded, replacement)
        let onDisk = try decodeOnDisk().entries
        XCTAssertEqual(onDisk, replacement)
    }

    /// Regression: when replaceAll is the **first** operation on a fresh store (with no prior all/add/update/remove
    /// triggering the lazy-load to create the directory), it must also create the directory and truly write to disk -- otherwise the data only stays in memory and the next process silently loses it.
    func testReplaceAllAsFirstOpPersistsOnFreshStore() async throws {
        let store = makeStore()
        let entries = [sampleEntry(canonical: "First")]
        await store.replaceAll(entries)

        // The on-disk file must exist and be legal JSON.
        let fileURL = tempDir.appending(component: "dictionary.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "when replaceAll is the first operation it should create the directory and write to disk")
        XCTAssertEqual(try decodeOnDisk().entries, entries)

        // A fresh store pointing at the same directory must re-read the content from disk (not read empty).
        let reloaded = await makeStore().all()
        XCTAssertEqual(reloaded, entries)
    }

    // MARK: - Fault tolerance: a missing / corrupt file starts with an empty dictionary, never crashing

    func testMissingFileStartsEmpty() async {
        // No dictionary.json under tempDir yet: all() should return empty and not crash.
        let store = makeStore()
        let entries = await store.all()
        XCTAssertTrue(entries.isEmpty)
    }

    func testCorruptFileStartsEmptyWithoutCrash() async throws {
        // First write garbage bytes to fake a corrupt file.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appending(component: "dictionary.json")
        try Data("{ not valid json".utf8).write(to: fileURL)

        let store = makeStore()
        let entries = await store.all()
        XCTAssertTrue(entries.isEmpty, "a corrupt file should start with an empty dictionary")

        // Afterwards it can still add/update normally and persist as legal JSON (the corrupt content is overwritten).
        let entry = sampleEntry()
        await store.add(entry)
        XCTAssertEqual(try decodeOnDisk().entries, [entry])
    }

    // MARK: - Tolerant decode (one bad entry must not wipe the whole dictionary)

    /// Writes a `dictionary.json` whose `entries` array contains the given raw JSON objects (already-serialized
    /// strings), so individual entries can be deliberately malformed without going through the typed encoder.
    private func writeRawEntriesFile(_ rawEntryObjects: [String]) throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appending(component: "dictionary.json")
        let joined = rawEntryObjects.joined(separator: ",\n")
        let json = "{\n  \"entries\": [\n\(joined)\n  ]\n}"
        try Data(json.utf8).write(to: fileURL, options: [.atomic])
    }

    /// A complete, valid raw entry JSON object string (every field present), for use in mixed-validity files.
    private func validRawEntry(id: String, canonical: String) -> String {
        """
        {
          "id": "\(id)",
          "canonical": "\(canonical)",
          "variants": ["v1"],
          "caseSensitive": false,
          "enabled": true,
          "scope": {"global": {}},
          "source": "manual",
          "createdAt": 0,
          "usageCount": 0
        }
        """
    }

    /// (a) A file with one malformed entry (missing `usageCount`) plus several good ones must load the good ones,
    /// not lose everything. This is the core data-loss regression: synthesized Codable fails the whole array on
    /// one bad element, then the next save overwrites the file -> all entries gone.
    func testOneMalformedEntryKeepsTheGoodOnes() async throws {
        let good1 = validRawEntry(id: "11111111-1111-1111-1111-111111111111", canonical: "Alpha")
        // Malformed: `usageCount` omitted -> keyNotFound under synthesized Codable.
        let bad = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "canonical": "Bravo",
          "variants": [],
          "caseSensitive": false,
          "enabled": true,
          "scope": {"global": {}},
          "source": "manual",
          "createdAt": 0
        }
        """
        let good2 = validRawEntry(id: "33333333-3333-3333-3333-333333333333", canonical: "Charlie")
        try writeRawEntriesFile([good1, bad, good2])

        let store = makeStore()
        let loaded = await store.all()
        let canonicals = loaded.map(\.canonical).sorted()
        // The malformed entry (Bravo) is recovered with usageCount defaulted to 0, and the good ones survive.
        XCTAssertEqual(canonicals, ["Alpha", "Bravo", "Charlie"])
    }

    /// (b) An unknown `Source` rawValue must default to `.manual` instead of dropping the entry / failing the load.
    func testUnknownSourceDefaultsToManual() async throws {
        let bad = """
        {
          "id": "44444444-4444-4444-4444-444444444444",
          "canonical": "Delta",
          "variants": [],
          "caseSensitive": false,
          "enabled": true,
          "scope": {"global": {}},
          "source": "fromTheFuture",
          "createdAt": 0,
          "usageCount": 5
        }
        """
        try writeRawEntriesFile([bad])

        let store = makeStore()
        let loaded = await store.all()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.canonical, "Delta")
        XCTAssertEqual(loaded.first?.source, .manual)
        XCTAssertEqual(loaded.first?.usageCount, 5)
    }

    /// (c) A missing `usageCount` must default to `0` (and other optional fields to their safe defaults).
    func testMissingUsageCountDefaultsToZero() async throws {
        let entry = """
        {
          "id": "55555555-5555-5555-5555-555555555555",
          "canonical": "Echo",
          "variants": ["e"],
          "scope": {"global": {}},
          "createdAt": 0
        }
        """
        try writeRawEntriesFile([entry])

        let store = makeStore()
        let loaded = await store.all()
        XCTAssertEqual(loaded.count, 1)
        let e = try XCTUnwrap(loaded.first)
        XCTAssertEqual(e.canonical, "Echo")
        XCTAssertEqual(e.usageCount, 0)
        XCTAssertFalse(e.caseSensitive)
        XCTAssertTrue(e.enabled)
        XCTAssertEqual(e.source, .manual)
    }

    /// An entry with a missing/empty `canonical` is droppable (cannot match anything), but must not poison the load.
    func testEntryWithEmptyCanonicalIsDroppedButOthersSurvive() async throws {
        let empty = """
        {
          "id": "66666666-6666-6666-6666-666666666666",
          "canonical": "",
          "variants": [],
          "scope": {"global": {}},
          "createdAt": 0,
          "usageCount": 0
        }
        """
        let good = validRawEntry(id: "77777777-7777-7777-7777-777777777777", canonical: "Foxtrot")
        try writeRawEntriesFile([empty, good])

        let store = makeStore()
        let loaded = await store.all()
        XCTAssertEqual(loaded.map(\.canonical), ["Foxtrot"])
    }

    /// (d) A fully-corrupt file is backed up to `dictionary.json.corrupt` and the store starts empty without crashing,
    /// so the next save does not overwrite the user's (recoverable) data.
    func testFullyCorruptFileIsBackedUpAndStartsEmpty() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appending(component: "dictionary.json")
        let corruptPayload = "{ not valid json at all"
        try Data(corruptPayload.utf8).write(to: fileURL)

        let store = makeStore()
        let entries = await store.all()
        XCTAssertTrue(entries.isEmpty, "a fully corrupt file should start with an empty dictionary")

        // The original (recoverable) bytes must have been preserved at the .corrupt sidecar.
        let backupURL = tempDir.appending(component: "dictionary.json.corrupt")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backupURL.path),
            "a fully corrupt file should be backed up to .corrupt before starting")
        let backupContents = try String(contentsOf: backupURL, encoding: .utf8)
        XCTAssertEqual(backupContents, corruptPayload, "the backup content should match the original corrupt bytes")

        // A subsequent save must not crash and produces legal JSON.
        let entry = sampleEntry()
        await store.add(entry)
        XCTAssertEqual(try decodeOnDisk().entries, [entry])
    }

    /// (e) The normal round-trip still works after the tolerant-decode changes (no regression on healthy files).
    func testTolerantDecodeNormalRoundTripStillWorks() async throws {
        let entry = DictionaryEntry(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            canonical: "Golf",
            variants: ["g", "golff"],
            caseSensitive: true,
            enabled: false,
            scope: .app(bundleID: "com.example.app"),
            source: .learnedFromEdit,
            createdAt: fixedDate,
            usageCount: 9
        )
        let store = makeStore()
        await store.add(entry)

        let reloaded = await makeStore().all()
        XCTAssertEqual(reloaded, [entry])
    }

    // MARK: - addLearned: dedup + variant-merge + usageCount bump

    /// First learned correction for a brand-new canonical: creates exactly one `.learnedFromEdit` entry with the heard
    /// form as its single variant and `usageCount == 1` (the first use).
    func testAddLearnedCreatesNewEntry() async throws {
        let store = makeStore()
        await store.addLearned(canonical: "Typeless", heard: "Type+")

        let entries = await store.all()
        XCTAssertEqual(entries.count, 1)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.canonical, "Typeless")
        XCTAssertEqual(e.variants, ["Type+"])
        XCTAssertEqual(e.source, .learnedFromEdit)
        XCTAssertEqual(e.usageCount, 1, "the first learned correction counts as one use")
    }

    /// CORE DEDUP REGRESSION: repeatedly correcting the SAME misheard -> corrected pair must NOT stack duplicate entries.
    /// The existing entry is reused; the new heard is merged into its variants (deduped) and usageCount bumped.
    func testAddLearnedSameCanonicalAndHeardMergesIntoOneEntry() async throws {
        let store = makeStore()
        await store.addLearned(canonical: "Typeless", heard: "Type+")
        await store.addLearned(canonical: "Typeless", heard: "Type+")
        await store.addLearned(canonical: "Typeless", heard: "Type+")

        let entries = await store.all()
        XCTAssertEqual(entries.count, 1, "the same (canonical, heard) pair must never stack duplicate entries")
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.variants, ["Type+"], "an already-known variant is not duplicated")
        XCTAssertEqual(e.usageCount, 3, "each repeat bumps usageCount")
        // The dedup must survive a process restart (it was actually committed to disk, not just deduped in memory).
        let reloaded = try decodeOnDisk().entries
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.usageCount, 3)
    }

    /// A NEW heard form for an EXISTING canonical is merged into that entry's variants (still one entry), and usageCount bumps.
    func testAddLearnedNewHeardMergesIntoExistingCanonical() async throws {
        let store = makeStore()
        await store.addLearned(canonical: "Typeless", heard: "Type+")
        await store.addLearned(canonical: "Typeless", heard: "type less")

        let entries = await store.all()
        XCTAssertEqual(entries.count, 1, "a new heard for the same canonical merges, never appends a second entry")
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.variants, ["Type+", "type less"], "the new heard is appended to the variant list")
        XCTAssertEqual(e.usageCount, 2)
    }

    /// Distinct canonicals stay separate entries (the merge keys on canonical, it does not collapse everything).
    func testAddLearnedDistinctCanonicalsStaySeparate() async throws {
        let store = makeStore()
        await store.addLearned(canonical: "Typeless", heard: "Type+")
        await store.addLearned(canonical: "TradingView", heard: "Trading Will")

        let entries = await store.all()
        XCTAssertEqual(Set(entries.map(\.canonical)), ["Typeless", "TradingView"])
        XCTAssertEqual(entries.count, 2)
    }

    /// Merging into an existing canonical preserves that entry's id (it is an in-place update, not a replace), so UI
    /// list identity / any external reference by id survives.
    func testAddLearnedMergeKeepsEntryId() async throws {
        let store = makeStore()
        await store.addLearned(canonical: "Typeless", heard: "Type+")
        let beforeEntries = await store.all()
        let originalID = try XCTUnwrap(beforeEntries.first?.id)

        await store.addLearned(canonical: "Typeless", heard: "type less")
        let afterEntries = await store.all()
        let mergedID = try XCTUnwrap(afterEntries.first?.id)
        XCTAssertEqual(mergedID, originalID, "merging must update the existing entry in place, keeping its id")
    }

    // MARK: - Change notification

    func testAddPostsChangeNotification() async {
        let center = NotificationCenter()
        let store = makeStore(notificationCenter: center)
        let exp = XCTNSNotificationExpectation(
            name: DictionaryStore.didChangeNotification, object: nil, notificationCenter: center)
        await store.add(sampleEntry())
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testRemovePostsChangeNotification() async {
        let center = NotificationCenter()
        let store = makeStore(notificationCenter: center)
        let entry = sampleEntry()
        await store.add(entry)

        let exp = XCTNSNotificationExpectation(
            name: DictionaryStore.didChangeNotification, object: nil, notificationCenter: center)
        await store.remove(id: entry.id)
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testNoopUpdateDoesNotPost() async {
        let center = NotificationCenter()
        let store = makeStore(notificationCenter: center)
        await store.add(sampleEntry())

        // update on a non-existent id: should not post a notification.
        let exp = XCTNSNotificationExpectation(
            name: DictionaryStore.didChangeNotification, object: nil, notificationCenter: center)
        exp.isInverted = true
        await store.update(sampleEntry(canonical: "Ghost"))
        await fulfillment(of: [exp], timeout: 0.3)
    }

    // MARK: - Default directory reuse convention

    func testDefaultBaseDirectoryIsApplicationSupportSayIt() {
        // Same root as ModelManager.downloadBase: Application Support/SayIt (not establishing a separate directory scheme).
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let expected = appSupport!.appending(component: "SayIt")
        XCTAssertEqual(DictionaryStore.defaultBaseDirectory, expected)
    }
}
