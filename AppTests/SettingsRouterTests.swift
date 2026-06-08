import XCTest
@testable import SayIt

/// Unit tests for ``SettingsRouter``, the consume-once hand-off the first-run guidance uses to open the
/// Settings window on the Speech tab instead of the default General tab.
@MainActor
final class SettingsRouterTests: XCTestCase {

    func testPendingTabDefaultsNil() {
        // A fresh router has no requested tab, so Settings opens on its default tab.
        let router = SettingsRouter()
        XCTAssertNil(router.pendingTab)
    }

    func testPendingTabRoundTrips() {
        let router = SettingsRouter()
        router.pendingTab = .stt
        XCTAssertEqual(router.pendingTab, .stt)
    }

    /// Models SettingsView's `.onAppear` consume: read the requested tab, then clear it so later opens
    /// are not forced back onto the same tab.
    func testConsumeOnceClearsPendingTab() {
        let router = SettingsRouter()
        router.pendingTab = .stt

        // Consume.
        let consumed = router.pendingTab
        if router.pendingTab != nil { router.pendingTab = nil }

        XCTAssertEqual(consumed, .stt)
        XCTAssertNil(router.pendingTab, "the request must be consumed exactly once")
    }
}
