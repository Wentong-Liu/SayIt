import XCTest
import AppKit
@testable import SayItCore

// MARK: - 测试桩

/// 内存版 pasteboard，不触碰系统真实剪贴板，记录所有操作便于断言。
@MainActor
final class FakePasteboard: PasteboardProtocol {
    private(set) var change = 0
    private var items: [[String: Data]] = []
    private(set) var writeCount = 0
    private(set) var restoreCount = 0

    var changeCount: Int { change }

    func snapshotItems() -> [[String: Data]] { items }

    func restoreItems(_ items: [[String: Data]]) {
        self.items = items
        change += 1
        restoreCount += 1
    }

    func string() -> String? {
        items.first?[NSPasteboard.PasteboardType.string.rawValue]
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    func writeString(_ text: String) -> Int {
        items = [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]
        change += 1
        writeCount += 1
        return change
    }

    /// 直接塞入预置内容，模拟「注入前剪贴板已有东西」。
    func seedString(_ text: String) {
        items = [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]
        change += 1
    }
}

@MainActor
final class StubKeystroke: KeystrokePosting {
    var result: Bool
    private(set) var postCount = 0
    init(result: Bool) { self.result = result }
    func postPaste() -> Bool {
        postCount += 1
        return result
    }
}

@MainActor
final class StubFrontmostProvider: FrontmostAppProviding {
    var target: InjectionTarget?
    init(target: InjectionTarget?) { self.target = target }
    func captureTarget() -> InjectionTarget? { target }
}

@MainActor
final class StubAXInserter: AXTextInserting {
    var trusted: Bool
    var insertResult: Bool
    private(set) var insertCount = 0
    init(trusted: Bool, insertResult: Bool) {
        self.trusted = trusted
        self.insertResult = insertResult
    }
    var isTrusted: Bool { trusted }
    func insert(_ text: String, into target: InjectionTarget) -> Bool {
        insertCount += 1
        return insertResult
    }
}

// MARK: - PasteboardBackup 纯逻辑测试

@MainActor
final class PasteboardBackupTests: XCTestCase {
    func testCaptureRecordsCurrentItemsAndChangeCount() {
        let pb = FakePasteboard()
        pb.seedString("original")
        let backup = PasteboardBackup.capture(from: pb)
        XCTAssertEqual(backup.changeCountAtSave, pb.changeCount)
        XCTAssertEqual(backup.items.count, 1)
    }

    func testRestorePutsBackOriginalContent() {
        let pb = FakePasteboard()
        pb.seedString("original")
        let backup = PasteboardBackup.capture(from: pb)

        pb.writeString("injected")
        XCTAssertEqual(pb.string(), "injected")

        backup.restore(to: pb)
        XCTAssertEqual(pb.string(), "original")
    }

    func testRestoreEmptyBackupClearsToCapturedEmptyState() {
        let pb = FakePasteboard()
        // 捕获时剪贴板为空。
        let backup = PasteboardBackup.capture(from: pb)
        XCTAssertTrue(backup.items.isEmpty)

        pb.writeString("injected")
        XCTAssertEqual(pb.string(), "injected")

        backup.restore(to: pb)
        XCTAssertNil(pb.string())
    }
}

// MARK: - TextInjector 编排测试

@MainActor
final class TextInjectorTests: XCTestCase {
    private func makeTarget() -> InjectionTarget {
        InjectionTarget(bundleIdentifier: "com.example.app", localizedName: "Example", processIdentifier: 123)
    }

    /// 不等待的 sleeper，避免拖慢测试；配合 await 让还原 Task 有机会执行。
    private let instantSleeper: @Sendable (Duration) async -> Void = { _ in await Task.yield() }

    func testEmptyTextIsNoOpSuccess() {
        let pb = FakePasteboard()
        let injector = TextInjector(
            pasteboard: pb,
            keystroke: StubKeystroke(result: true),
            frontmostProvider: StubFrontmostProvider(target: makeTarget()),
            axInserter: StubAXInserter(trusted: false, insertResult: false),
            sleeper: instantSleeper
        )
        let result = injector.inject("")
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(pb.writeCount, 0, "空文本不应写剪贴板")
    }

    func testNoFrontmostAppLeavesTextInPasteboardAndFails() {
        let pb = FakePasteboard()
        let injector = TextInjector(
            pasteboard: pb,
            keystroke: StubKeystroke(result: true),
            frontmostProvider: StubFrontmostProvider(target: nil),
            axInserter: StubAXInserter(trusted: false, insertResult: false),
            sleeper: instantSleeper
        )
        let result = injector.inject("hello")
        guard case .failedTextLeftInPasteboard = result else {
            return XCTFail("无前台 App 应返回 failedTextLeftInPasteboard，实得 \(result)")
        }
        XCTAssertEqual(pb.string(), "hello", "失败时文本应保留在剪贴板")
    }

    func testPasteboardPathSavesWritesPastesAndRestores() async {
        let pb = FakePasteboard()
        pb.seedString("clipboard-original")
        let keystroke = StubKeystroke(result: true)
        let injector = TextInjector(
            pasteboard: pb,
            keystroke: keystroke,
            frontmostProvider: StubFrontmostProvider(target: makeTarget()),
            axInserter: StubAXInserter(trusted: false, insertResult: false),
            sleeper: instantSleeper
        )

        let result = injector.inject("dictated text")
        XCTAssertEqual(result, .success(method: .pasteboard))
        XCTAssertEqual(keystroke.postCount, 1, "应模拟一次 ⌘V")

        // 让延迟还原的 Task 跑完。
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(pb.string(), "clipboard-original", "粘贴后应还原原剪贴板")
        XCTAssertGreaterThanOrEqual(pb.restoreCount, 1)
    }

    func testPastePostFailureLeavesTextInPasteboardNoRestore() {
        let pb = FakePasteboard()
        pb.seedString("clipboard-original")
        let injector = TextInjector(
            pasteboard: pb,
            keystroke: StubKeystroke(result: false),
            frontmostProvider: StubFrontmostProvider(target: makeTarget()),
            axInserter: StubAXInserter(trusted: false, insertResult: false),
            sleeper: instantSleeper
        )

        let result = injector.inject("dictated text")
        guard case .failedTextLeftInPasteboard = result else {
            return XCTFail("⌘V 失败应返回 failedTextLeftInPasteboard，实得 \(result)")
        }
        XCTAssertEqual(pb.string(), "dictated text", "⌘V 失败时注入文本应留在剪贴板")
        XCTAssertEqual(pb.restoreCount, 0, "⌘V 失败时不应还原（否则会盖掉留给用户的文本）")
    }

    func testAccessibilityPathPreferredAndSucceedsWithoutTouchingPasteboard() {
        let pb = FakePasteboard()
        pb.seedString("clipboard-original")
        let ax = StubAXInserter(trusted: true, insertResult: true)
        let injector = TextInjector(
            configuration: .init(preferAccessibility: true),
            pasteboard: pb,
            keystroke: StubKeystroke(result: true),
            frontmostProvider: StubFrontmostProvider(target: makeTarget()),
            axInserter: ax,
            sleeper: instantSleeper
        )

        let result = injector.inject("via ax")
        XCTAssertEqual(result, .success(method: .accessibility))
        XCTAssertEqual(ax.insertCount, 1)
        XCTAssertEqual(pb.writeCount, 0, "AX 成功时不应碰剪贴板")
        XCTAssertEqual(pb.string(), "clipboard-original", "AX 成功时剪贴板原内容不变")
    }

    func testAccessibilityFailureFallsBackToPasteboard() async {
        let pb = FakePasteboard()
        pb.seedString("clipboard-original")
        let ax = StubAXInserter(trusted: true, insertResult: false)
        let keystroke = StubKeystroke(result: true)
        let injector = TextInjector(
            configuration: .init(preferAccessibility: true),
            pasteboard: pb,
            keystroke: keystroke,
            frontmostProvider: StubFrontmostProvider(target: makeTarget()),
            axInserter: ax,
            sleeper: instantSleeper
        )

        let result = injector.inject("fallback text")
        XCTAssertEqual(result, .success(method: .pasteboard))
        XCTAssertEqual(ax.insertCount, 1, "应先尝试 AX")
        XCTAssertEqual(keystroke.postCount, 1, "AX 失败后应回退剪贴板粘贴")

        await Task.yield()
        await Task.yield()
        XCTAssertEqual(pb.string(), "clipboard-original")
    }
}

// MARK: - InjectionTarget 捕获测试

@MainActor
final class InjectionTargetTests: XCTestCase {
    func testInitFromRunningApplicationCapturesIdentity() {
        // 用当前测试进程作为 NSRunningApplication 来源，验证字段拷贝。
        let current = NSRunningApplication.current
        let target = InjectionTarget(running: current)
        XCTAssertEqual(target.processIdentifier, current.processIdentifier)
        XCTAssertEqual(target.bundleIdentifier, current.bundleIdentifier)
        XCTAssertEqual(target.localizedName, current.localizedName)
    }
}
