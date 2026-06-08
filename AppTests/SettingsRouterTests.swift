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

    // MARK: - requestOpen(tab:) — the load-bearing contract the first-run fix depends on

    /// `requestOpen(tab:)` is the single call the AppDelegate first-run path makes, and the entire fix
    /// rests on its two side effects: it must (a) set `pendingTab` so SettingsView lands on the right tab,
    /// and (b) bump `openRequestID` so the observing scene's `.onChange` fires and calls `openSettings()`.
    func testRequestOpenSetsPendingTabAndBumpsRequestID() {
        let router = SettingsRouter()
        XCTAssertEqual(router.openRequestID, 0, "a fresh router has no outstanding request")

        router.requestOpen(tab: .stt)

        XCTAssertEqual(router.pendingTab, .stt, "requestOpen must record the requested tab for SettingsView to consume")
        XCTAssertEqual(router.openRequestID, 1, "requestOpen must bump openRequestID to signal the observing scene")
    }

    /// `requestOpen(tab: nil)` still signals an open (the default-General path); a `nil` tab must not be
    /// mistaken for "no request" — the id has to advance so the scene actually opens the window.
    func testRequestOpenWithNilTabStillBumpsRequestID() {
        let router = SettingsRouter()

        router.requestOpen(tab: nil)

        XCTAssertNil(router.pendingTab, "a nil tab means open on the default General tab")
        XCTAssertEqual(router.openRequestID, 1, "even a default-tab request must bump openRequestID")
    }

    /// `openSettingsIfRequested()`'s guard is exactly `requestID != 0, requestID != handled`. This pins the
    /// two invariants that guard relies on: after any request the id is non-zero, and it strictly increases
    /// across repeated requests so each new open is detected as new rather than swallowed as already-handled.
    func testOpenRequestIDStaysNonZeroAndStrictlyIncreasesAcrossRequests() {
        let router = SettingsRouter()

        router.requestOpen(tab: .stt)
        let first = router.openRequestID
        XCTAssertNotEqual(first, 0, "a made request must produce a non-zero id (the guard's `requestID != 0`)")

        router.requestOpen(tab: .general)
        let second = router.openRequestID
        XCTAssertGreaterThan(second, first, "each new request must advance the id so the scene treats it as new")
        XCTAssertNotEqual(second, 0)

        router.requestOpen(tab: nil)
        let third = router.openRequestID
        XCTAssertGreaterThan(third, second, "ids must remain strictly monotonic across further requests")
        XCTAssertNotEqual(third, 0)
    }
}
