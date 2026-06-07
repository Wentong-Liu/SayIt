import XCTest
@testable import SayItCore

/// Verifies the bundled chime cue resources are present and resolvable via `Bundle.module`.
///
/// This is the headless proof that `.copy("Resources/start.caf")` / `stop.caf` in `Package.swift` land in the
/// SwiftPM resource bundle and resolve at runtime (the same mechanism as `Localizable.xcstrings`). It does NOT
/// play audio — CI must stay silent — it only asserts the URLs and metadata, then exercises the player's
/// fire-and-forget `play(_:)` to confirm it never throws.
@MainActor
final class SoundCuePlayerTests: XCTestCase {

    func testCueResourcesResolveInBundle() throws {
        for cue in [SoundCue.start, SoundCue.stop] {
            let url = try XCTUnwrap(
                Bundle.module.url(forResource: cue.resourceName, withExtension: "caf"),
                "\(cue) cue must resolve in Bundle.module"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(cue) cue file must exist at the resolved URL")
        }
    }

    func testResourceNamesMatchRawValues() {
        XCTAssertEqual(SoundCue.start.resourceName, "start")
        XCTAssertEqual(SoundCue.stop.resourceName, "stop")
    }

    /// The real player must be safe to call fire-and-forget without throwing, even in a headless test process.
    func testPlayerDoesNotThrowOnPlay() {
        let player = SoundCuePlayer()
        player.play(.start)
        player.play(.stop)
        // Reaching here without a crash/throw is the assertion; playback itself is asynchronous and confirmed on-device.
    }
}
