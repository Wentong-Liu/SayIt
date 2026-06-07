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
            "replaceAll 作为首个操作时应建目录并落盘")
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
        XCTAssertTrue(entries.isEmpty, "损坏文件应以空词典起步")

        // Afterwards it can still add/update normally and persist as legal JSON (the corrupt content is overwritten).
        let entry = sampleEntry()
        await store.add(entry)
        XCTAssertEqual(try decodeOnDisk().entries, [entry])
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
