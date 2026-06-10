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

    // MARK: - rapid stop/start awaits the in-flight stop before starting

    /// Regression: a rapid `stopTesting()` -> `startTesting()` must `await` the in-flight stop's
    /// `recorder.stop()` BEFORE the next `recorder.start()` reaches the actor.
    ///
    /// Root cause guarded: `stopTesting()` used to fire an untracked `Task { _ = try? await recorder.stop() }`. The
    /// immediately-following `startTesting()` then called `recorder.start()` while that stop was still tearing down the
    /// `AVAudioEngine` — racing the teardown (the real recorder would throw `.alreadyRecording` / rebuild racily). The
    /// fix tracks the stop in `pendingStopTask` and awaits it via `awaitPendingStop()` before start.
    ///
    /// Determinism: the fake's `stop()` is gated to pin the recorder in the "stop in flight, still recording" window.
    /// While gated, the second `startTesting()`'s level task must be BLOCKED in `awaitPendingStop()` — so `startCount`
    /// must NOT advance. Releasing the gate lets the stop finish, after which `start()` finally runs.
    func testRapidStopThenStartAwaitsPendingStopBeforeStart() async throws {
        let config = makeConfig()
        let recorder = FakeAudioRecorder()
        let vm = MicTestViewModel(config: config, recorder: recorder)

        // First start: capture is live.
        vm.startTesting()
        try await pollUntil { await recorder.startCount == 1 }

        // Arm the stop gate so the NEXT stop() suspends (still recording) until released.
        await recorder.gateStop()

        // Rapid stop -> start. stopTesting() spawns the tracked pendingStopTask (which enters gated stop()),
        // then startTesting() spawns a level task that must await that pending stop before recorder.start().
        vm.stopTesting()
        await recorder.waitUntilStopGated()   // ensure the stop is actually parked in the gate
        vm.startTesting()

        // While the stop is gated, the new start MUST be blocked in awaitPendingStop(): startCount stays at 1.
        // Give the (would-be racing) start task several scheduler turns to (wrongly) run start() if unfixed.
        for _ in 0..<50 { await Task.yield() }
        let countWhileGated = await recorder.startCount
        XCTAssertEqual(countWhileGated, 1,
                       "the second start must await the in-flight stop; it must NOT start while the stop is still tearing down")

        // Release the stop: it finishes, then the awaited start runs.
        await recorder.releaseStop()
        try await pollUntil { await recorder.startCount == 2 }
        let stops = await recorder.stopCount
        XCTAssertEqual(stops, 1, "exactly one stop ran for the single stopTesting()")

        vm.onDisappear()
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
