import XCTest
@testable import SayItCore

/// DictionaryEntry / UserDictionary 的 Codable 往返单测（确定性：固定 UUID + 固定 Date）。
final class DictionaryEntryCodableTests: XCTestCase {

    /// 固定时间，规避 `Date()` 默认值带来的不确定性，使相等断言可重复。
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
        // 只传 canonical（+variants）即可建一条「手动 / 全局 / 启用 / 大小写不敏感」词条。
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

/// DictionaryStore 持久化 + 变更通知单测：全部经注入的临时目录，绝不碰真实词典。
final class DictionaryStoreTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// 每个用例独立临时根目录；tearDown 清理（镜像 ModelManagerTests 的 makeTempDir 风格）。
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

    /// 直接从磁盘读 dictionary.json 并解码，证明原子写盘后留下的是合法 JSON。
    private func decodeOnDisk() throws -> UserDictionary {
        let fileURL = tempDir.appending(component: "dictionary.json")
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(UserDictionary.self, from: data)
    }

    // MARK: - 持久化往返（新建一个 store 从盘里重读）

    func testAddPersistsAcrossFreshStore() async throws {
        let entry = sampleEntry()
        let store1 = makeStore()
        await store1.add(entry)

        // 全新 store 指向同一临时目录：读到的内容必须来自磁盘（而非内存）。
        let store2 = makeStore()
        let loaded = await store2.all()
        XCTAssertEqual(loaded, [entry])

        // 盘上文件存在且为合法 JSON。
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

        // 一个不在词典里的 id：update 不应改变任何内容。
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

    // MARK: - 容错：缺失 / 损坏文件以空词典起步，绝不崩溃

    func testMissingFileStartsEmpty() async {
        // tempDir 下尚无 dictionary.json：all() 应返回空且不崩溃。
        let store = makeStore()
        let entries = await store.all()
        XCTAssertTrue(entries.isEmpty)
    }

    func testCorruptFileStartsEmptyWithoutCrash() async throws {
        // 先写入垃圾字节冒充损坏文件。
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appending(component: "dictionary.json")
        try Data("{ not valid json".utf8).write(to: fileURL)

        let store = makeStore()
        let entries = await store.all()
        XCTAssertTrue(entries.isEmpty, "损坏文件应以空词典起步")

        // 之后仍可正常增改并落盘成合法 JSON（损坏内容被覆盖）。
        let entry = sampleEntry()
        await store.add(entry)
        XCTAssertEqual(try decodeOnDisk().entries, [entry])
    }

    // MARK: - 变更通知

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

        // 对不存在的 id 做 update：不应投递通知。
        let exp = XCTNSNotificationExpectation(
            name: DictionaryStore.didChangeNotification, object: nil, notificationCenter: center)
        exp.isInverted = true
        await store.update(sampleEntry(canonical: "Ghost"))
        await fulfillment(of: [exp], timeout: 0.3)
    }

    // MARK: - 默认目录复用约定

    func testDefaultBaseDirectoryIsApplicationSupportSayIt() {
        // 与 ModelManager.downloadBase 同根：Application Support/SayIt（不另立目录方案）。
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
