#if canImport(AppKit)
import XCTest
import AppKit
@testable import SayItCore

/// Locks the exact NSPanel configuration both HUD controllers depend on, now centralized in `HUDPanelFactory`.
/// Asserts the nine shared fields are constant across parameter combinations and the three parameterized fields
/// (content size, ignoresMouseEvents, content view) reflect their arguments. A trivial `NSView()` stands in for the
/// SwiftUI host so no SwiftUI rendering is exercised.
@MainActor
final class HUDPanelFactoryTests: XCTestCase {

    func testRecordingStylePanelConfiguration() {
        let size = NSSize(width: 160, height: 56)
        let content = NSView()
        let panel = HUDPanelFactory.makePanel(contentSize: size, ignoresMouseEvents: true, contentView: content)

        assertSharedFields(panel)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.contentView, content)
        XCTAssertEqual(panel.contentView?.frame.size, size)
    }

    func testSuggestionStylePanelConfiguration() {
        let size = NSSize(width: 280, height: 64)
        let content = NSView()
        let panel = HUDPanelFactory.makePanel(contentSize: size, ignoresMouseEvents: false, contentView: content)

        assertSharedFields(panel)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.contentView, content)
        XCTAssertEqual(panel.contentView?.frame.size, size)
    }

    /// The nine fields that must be identical for every HUD panel regardless of parameters.
    private func assertSharedFields(_ panel: NSPanel) {
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.isMovable)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
    }
}
#endif
