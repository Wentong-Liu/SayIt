import XCTest
@testable import SayItCore

/// Verifies the bundled chime cue resources are present and resolvable via `Bundle.module`, and that the
/// player constructs cleanly — all without rendering any audio (CI must stay silent).
///
/// This is the headless proof that `.copy("Resources/start.caf")` / `stop.caf` in `Package.swift` land in the
/// SwiftPM resource bundle and resolve at runtime (the same mechanism as `Localizable.xcstrings`). It does NOT
/// play audio — it only asserts the URLs and metadata, plus that `SoundCuePlayer()` constructs without throwing.
/// Actual playback is fire-and-forget and confirmed on-device, not in this silent test.
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

    /// The real player must construct cleanly in a headless test process WITHOUT rendering audio.
    /// Production `play(_:)` is non-throwing (guard-let, never throws), so calling it here would add zero
    /// coverage while emitting an audible chime; we therefore only assert construction. Playback is
    /// fire-and-forget and asynchronous, confirmed on-device — never in this silent test.
    func testPlayerConstructsWithoutPlaying() {
        let player = SoundCuePlayer()
        XCTAssertNotNil(player, "SoundCuePlayer must construct without throwing or playing audio")
    }
}
