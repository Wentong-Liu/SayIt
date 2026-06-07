import Observation
import XCTest
@testable import SayIt
@testable import SayItCore

/// Unit tests for ``DictionaryViewModel``: the main-actor mirror that wraps the ``DictionaryStore`` actor for the
/// Dictionary settings pane. Each test injects a temp-directory store + isolated NotificationCenter (mirroring
/// `DictionaryStoreTests`), never touching real user data.
///
/// Coverage:
/// - add → mirror reflects + persists across a "relaunch" (a fresh store on the same directory).
/// - update → mutates and preserves id / createdAt / usageCount.
/// - remove → drops it.
/// - an external store write fires `didChangeNotification` → the view-model reloads (live update).
/// - the `entries` mirror write invalidates the view (`withObservationTracking`).
/// - `sanitize` trims / dedups / drops empties / drops canonical-equal variants.
@MainActor
final class DictionaryViewModelTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appending(component: "sayit-dictvm-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    private func makeStore(notificationCenter: NotificationCenter = .default) -> DictionaryStore {
        DictionaryStore(baseDirectory: tempDir, notificationCenter: notificationCenter)
    }

    // MARK: - sanitize (pure)

    func testSanitizeTrimsDropsEmptiesDedupsAndDropsCanonicalEqual() {
        let raw = ["  use effect  ", "", "UseEffect", "use effect", "useEffect", "   ", "UseEffect"]
        let result = DictionaryViewModel.sanitize(raw, canonical: "useEffect")
        // Trimmed; empties dropped; the exact-canonical-equal ("useEffect") dropped; dedup preserving first-seen order.
        XCTAssertEqual(result, ["use effect", "UseEffect"])
    }

    func testSanitizeEmptyInputIsEmpty() {
        XCTAssertEqual(DictionaryViewModel.sanitize([], canonical: "X"), [])
        XCTAssertEqual(DictionaryViewModel.sanitize(["  ", "\n"], canonical: "X"), [])
    }

    // MARK: - add

    func testAddReflectsInMirrorAndPersists() async throws {
        let vm = DictionaryViewModel(store: makeStore())
        await vm.add(canonical: "useEffect", variants: ["use effect", "  "], caseSensitive: false, enabled: true)

        XCTAssertEqual(vm.entries.count, 1)
        let entry = try XCTUnwrap(vm.entries.first)
        XCTAssertEqual(entry.canonical, "useEffect")
        XCTAssertEqual(entry.variants, ["use effect"]) // sanitized
        XCTAssertEqual(entry.scope, .global)
        XCTAssertEqual(entry.source, .manual)

        // Survives "relaunch": a fresh store on the same directory re-reads from disk.
        let reloaded = await makeStore().all()
        XCTAssertEqual(reloaded, vm.entries)
    }

    func testAddEmptyCanonicalIsIgnored() async {
        let vm = DictionaryViewModel(store: makeStore())
        await vm.add(canonical: "   ", variants: ["x"], caseSensitive: false, enabled: true)
        XCTAssertTrue(vm.entries.isEmpty)
    }

    // MARK: - update preserves identity fields

    func testUpdatePreservesIdCreatedAtUsageCount() async throws {
        let store = makeStore()
        let original = DictionaryEntry(
            id: UUID(),
            canonical: "useEffect",
            variants: ["use effect"],
            createdAt: fixedDate,
            usageCount: 5
        )
        await store.add(original)
        let vm = DictionaryViewModel(store: store)
        await vm.reload()

        var mutated = try XCTUnwrap(vm.entries.first)
        mutated.canonical = "useMemo"
        mutated.variants = ["use memo"]
        await vm.update(mutated)

        let updated = try XCTUnwrap(vm.entries.first)
        XCTAssertEqual(updated.canonical, "useMemo")
        XCTAssertEqual(updated.variants, ["use memo"])
        // Identity fields preserved.
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.createdAt, fixedDate)
        XCTAssertEqual(updated.usageCount, 5)
    }

    // MARK: - setEnabled

    func testSetEnabledWritesThrough() async throws {
        let store = makeStore()
        await store.add(DictionaryEntry(canonical: "useEffect", variants: ["use effect"], enabled: true))
        let vm = DictionaryViewModel(store: store)
        await vm.reload()

        let entry = try XCTUnwrap(vm.entries.first)
        await vm.setEnabled(false, for: entry)
        XCTAssertEqual(vm.entries.first?.enabled, false)

        // Persisted.
        let reloaded = await makeStore().all()
        XCTAssertEqual(reloaded.first?.enabled, false)
    }

    // MARK: - remove

    func testRemoveDropsEntry() async throws {
        let store = makeStore()
        let entry = DictionaryEntry(canonical: "useEffect", variants: ["use effect"])
        await store.add(entry)
        let vm = DictionaryViewModel(store: store)
        await vm.reload()
        XCTAssertEqual(vm.entries.count, 1)

        await vm.remove(id: entry.id)
        XCTAssertTrue(vm.entries.isEmpty)
        let reloaded = await makeStore().all()
        XCTAssertTrue(reloaded.isEmpty)
    }

    // MARK: - live update via didChangeNotification

    func testExternalStoreWriteTriggersReload() async throws {
        let center = NotificationCenter()
        let store = makeStore(notificationCenter: center)
        let vm = DictionaryViewModel(store: store, notificationCenter: center)
        vm.startObserving()
        await vm.reload()
        XCTAssertTrue(vm.entries.isEmpty)

        // Simulate a change from another code path: write through the same store, which posts didChange on `center`.
        let entry = DictionaryEntry(canonical: "useEffect", variants: ["use effect"])
        await store.add(entry)

        // The observer handler reloads asynchronously on the main queue; poll until it reflects.
        let appeared = try await waitUntil { vm.entries.count == 1 }
        XCTAssertTrue(appeared, "list should update live after an external store change")
        XCTAssertEqual(vm.entries.first?.canonical, "useEffect")

        vm.stopObserving()
    }

    // MARK: - Observation: mirror write invalidates the view

    func testEntriesMirrorWriteFiresObservation() async {
        let vm = DictionaryViewModel(store: makeStore())
        let didChange = expectation(description: "entries mirror write invalidates the view")
        withObservationTracking {
            _ = vm.entries
        } onChange: {
            didChange.fulfill()
        }
        await vm.add(canonical: "useEffect", variants: ["use effect"], caseSensitive: false, enabled: true)
        await fulfillment(of: [didChange], timeout: 1.0)
    }

    // MARK: - Helper

    /// Polls `condition` on the main actor until true or the timeout elapses; returns whether it became true.
    private func waitUntil(timeout: TimeInterval = 1.0, _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        return condition()
    }
}
