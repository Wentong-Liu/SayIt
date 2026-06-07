import Observation
import XCTest
@testable import SayIt
@testable import SayItCore

/// Regression tests for `MicTestViewModel.selectedUID`, mirroring `SettingsViewModelObservationTests`.
///
/// Root cause (same class of bug PR #18 fixed in `SettingsViewModel`): `selectedUID` was a *computed*
/// `get`/`set` forwarding to `AppConfig.inputDeviceUID` (a plain, non-`@Observable` class). The `@Observable`
/// macro only injects Observation tracking (`access` in the getter, `withMutation` in the setter) for **stored**
/// properties — computed properties get none. So the device Picker bound to `$micVM.selectedUID` wrote the new
/// value through (the change *applied* and *persisted*) but SwiftUI was never told the property changed, so the
/// Picker kept rendering the OLD selection. Converting it to a stored mirror with a write-through `didSet` fixes it.
///
/// These tests model SwiftUI's invalidation with `withObservationTracking`, plus the write-through to config,
/// the init seeding, and the restart-on-device-switch trigger that goes through the `didSet`.
@MainActor
final class MicTestViewModelObservationTests: XCTestCase {

    /// An isolated `AppConfig` on a throwaway `UserDefaults` suite (never touches `.standard`).
    private func makeConfig() -> AppConfig {
        let suite = "test.mictestvm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return AppConfig(defaults: defaults)
    }

    /// Reads `read()` once under observation tracking, then runs `mutate()` and asserts the
    /// tracked read property fired its change notification — i.e. SwiftUI would re-render.
    private func assertObservationFires(
        read: @escaping () -> Void,
        mutate: () -> Void,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let didChange = expectation(description: message)
        withObservationTracking {
            read()
        } onChange: {
            didChange.fulfill()
        }
        mutate()
        wait(for: [didChange], timeout: 1.0)
    }

    // MARK: - selectedUID stored-mirror

    func testSelectedUIDChangeFiresObservationAndPersists() {
        let config = makeConfig()
        let vm = MicTestViewModel(config: config, recorder: FakeAudioRecorder())
        XCTAssertNil(vm.selectedUID, "fresh config has no persisted device")
        let next = "uid-new"

        assertObservationFires(read: { _ = vm.selectedUID }, mutate: { vm.selectedUID = next },
                               "selectedUID change should invalidate the view")
        XCTAssertEqual(vm.selectedUID, next, "new value should be reflected")
        XCTAssertEqual(config.inputDeviceUID, next, "new value should persist to config")
    }

    func testInitSeedsSelectedUIDFromConfig() {
        let config = makeConfig()
        config.inputDeviceUID = "uid-x"
        let vm = MicTestViewModel(config: config, recorder: FakeAudioRecorder())
        XCTAssertEqual(vm.selectedUID, "uid-x", "init should seed selectedUID from the persisted config value")
    }

    // MARK: - restart on device switch while testing

    func testSwitchingDeviceWhileTestingRestartsCaptureWithNewDevice() async throws {
        let config = makeConfig()
        let recorder = FakeAudioRecorder()
        let vm = MicTestViewModel(config: config, recorder: recorder)

        vm.startTesting()
        // Let the start task reach (and complete) recorder.start.
        try await pollUntil { await recorder.startCount == 1 }
        let firstDevice = await recorder.lastStartDeviceUID
        XCTAssertNil(firstDevice, "first start uses the (nil) system-default device")

        // Switch the device while testing: didSet -> restartTesting -> makeLevelTask(reads selectedUID).
        vm.selectedUID = "uid-switched"

        try await pollUntil { await recorder.startCount == 2 }
        let secondDevice = await recorder.lastStartDeviceUID
        XCTAssertEqual(secondDevice, "uid-switched",
                       "the restart should start capture with the just-picked device")
        XCTAssertEqual(config.inputDeviceUID, "uid-switched", "the pick should also persist to config")

        vm.onDisappear()
    }

    func testSwitchingDeviceWhileNotTestingDoesNotStart() async throws {
        let config = makeConfig()
        let recorder = FakeAudioRecorder()
        let vm = MicTestViewModel(config: config, recorder: recorder)

        vm.selectedUID = "uid-while-idle"
        // Give any (erroneous) task a chance to run.
        await Task.yield()
        let count = await recorder.startCount
        XCTAssertEqual(count, 0, "picking a device while not testing must not start capture")
        XCTAssertEqual(config.inputDeviceUID, "uid-while-idle", "the pick still persists")
    }

    // MARK: - Helpers

    /// Polls `condition` (an async actor read) until true or a short timeout elapses.
    private func pollUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }
}
