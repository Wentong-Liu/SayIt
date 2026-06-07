import Observation
import os
import SwiftUI
import SayItCore

/// The view model for the "Microphone" area in the "General" settings page: carries the device list, the currently selected device,
/// and the live level-capture state of "test microphone".
///
/// Decoupled from ``SettingsViewModel`` (this task does not change it), self-managing a separate ``AudioRecorder``
/// used only for test capture -- on test, `start()`s the selected device, subscribes to the `levels` stream, and switches the normalized level back to
/// `@MainActor` to update ``level`` for the VU level bar to bind; stops on stopping/leaving the page.
///
/// The selected device is written to ``AppConfig/inputDeviceUID`` (`nil` = follow the system default).
@MainActor
@Observable
final class MicTestViewModel {
    /// The injected config; defaults to `.shared`, previews/unit tests can pass an isolated instance.
    @ObservationIgnored private let config: AppConfig

    /// The recorder used only for "test microphone" (not interfering with the end-to-end dictation recorder).
    @ObservationIgnored private let recorder: AudioRecording

    /// The task consuming the `levels` stream in the background; cancelled on stopping the test.
    @ObservationIgnored private var levelTask: Task<Void, Never>?

    /// Monotonic id of the current level-consuming task. Bumped each time a new level task is created
    /// (start/restart); each task captures its own generation and only writes ``level`` while it still
    /// matches. This closes the post-suspension stale-write race: a cancelled OLD task that already
    /// passed its `Task.isCancelled` check can still resume from its `MainActor.run` hop AFTER a newer
    /// task zeroed the level, and the generation mismatch makes it drop that stale VU sample.
    @ObservationIgnored private var levelGeneration = 0

    /// Mic-test logging (same subsystem/category as ``SettingsViewModel`` so start failures land in the same place).
    @ObservationIgnored private let log = Logger(subsystem: "com.liuwentong.SayIt", category: "settings")

    /// The selectable input device list (with the "System Default" option presented separately by the UI).
    private(set) var devices: [AudioInputDevice] = []

    /// The system's current default input device UID (used to annotate "(System Default)" in the dropdown).
    private(set) var systemDefaultUID: String?

    /// Whether a microphone test capture is in progress.
    private(set) var isTesting: Bool = false

    /// The latest normalized input level (0...1), for the level bar to bind. Returns to 0 after stopping.
    private(set) var level: Double = 0

    /// The device UID selected in the UI; `nil` means "System Default".
    ///
    /// This is an `@Observable`-tracked **stored** property (write-through to `config`), not a pure computed forward.
    /// The `@Observable` macro only injects Observation tracking (`access` in the getter / `withMutation` in the setter)
    /// for stored properties; if this read/wrote `config.inputDeviceUID` instead (`AppConfig` is not `@Observable`),
    /// the device Picker bound to `$micVM.selectedUID` would write through and persist but SwiftUI would never be told the
    /// property changed, so the Picker would keep showing the OLD selection (the same defect PR #18 fixed for
    /// ``SettingsViewModel``). Storing it here reflects the pick instantly and persists it.
    ///
    /// The `didSet` writes through to ``AppConfig/inputDeviceUID``; if a test is in progress it restarts capture with the new device.
    var selectedUID: String? {
        didSet {
            guard selectedUID != oldValue else { return }
            config.inputDeviceUID = selectedUID
            if isTesting {
                // Switching the device takes effect instantly: restart the test capture to the new device.
                restartTesting()
            }
        }
    }

    /// - Parameters:
    ///   - config: the injected config; defaults to `.shared`.
    ///   - recorder: the injected recorder; defaults to a new ``AudioRecorder`` (unit tests can pass a fake implementation).
    init(config: AppConfig = .shared, recorder: AudioRecording = AudioRecorder()) {
        self.config = config
        self.recorder = recorder
        // Seed the observable mirror from the persisted value (write-through to config happens in didSet afterwards).
        self.selectedUID = config.inputDeviceUID
    }

    /// Refreshes the selectable device list and the system default device (called on entering the page or after device plug/unplug).
    func refreshDevices() {
        devices = AudioInputDeviceManager.availableInputDevices()
        systemDefaultUID = AudioInputDeviceManager.defaultInputDeviceUID()
    }

    /// Toggles the test switch (one button click: if not testing, start; if testing, stop).
    func toggleTesting() {
        if isTesting {
            stopTesting()
        } else {
            startTesting()
        }
    }

    /// Starts capturing with the selected device and refreshes the level in real time. Ignored if already testing.
    func startTesting() {
        guard !isTesting else { return }
        isTesting = true
        // `selectedUID` is the live source of truth (kept in sync with config via its didSet),
        // so a device picked while not testing is honored on start.
        let deviceUID = selectedUID
        levelGeneration += 1
        levelTask = makeLevelTask(deviceUID: deviceUID, stopFirst: false, generation: levelGeneration)
    }

    /// Constructs the capture task: optionally `stop()` first (for switching the device on restart), then `start(deviceUID:)`,
    /// then serially consumes the level stream in the same task -- guaranteeing stop always reaches the actor before start.
    ///
    /// Note: ``AudioRecorder/levels`` is a single-consumer stream,
    /// only one task should `for await` it at a time; here this is guaranteed by cancelling the old task before building a new one.
    private func makeLevelTask(deviceUID: String?, stopFirst: Bool, generation: Int) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            if stopFirst {
                // Stop the old capture first: when not recording it throws .notRecording, which is just ignored in the device-switch scenario.
                _ = try? await self.recorder.stop()
            }
            do {
                try await self.recorder.start(deviceUID: deviceUID)
            } catch {
                // Start failure (no permission/device busy): log the bound error so a mic-denied / device-busy
                // failure is distinguishable from a stuck-at-0 level, then reset the state and zero the level.
                self.log.error("Mic test start failed for device \(deviceUID ?? "system-default", privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.isTesting = false
                    self.level = 0
                }
                return
            }
            // Subscribe to the level stream; switch the normalized value back to MainActor to update the UI. The stream produces 0 after stop() and stays valid.
            for await value in self.recorder.levels {
                if Task.isCancelled { break }
                await MainActor.run {
                    // Drop the sample if a newer level task has since taken over (e.g. this task was cancelled
                    // and restartTesting already zeroed the level): a stale VU value must not resurrect it.
                    guard self.levelGeneration == generation else { return }
                    self.level = value
                }
            }
        }
    }

    /// Stops the test capture, zeroing the level. Ignored if not testing.
    func stopTesting() {
        guard isTesting else { return }
        isTesting = false
        level = 0
        levelTask?.cancel()
        levelTask = nil
        Task { [recorder] in
            // stop() throws .notRecording when not recording; just ignored in the test scenario.
            _ = try? await recorder.stop()
        }
    }

    /// Restarts the test capture with the currently selected device (called when switching the device).
    ///
    /// Cancels the old level-consuming task (releasing the single-consumer `levels` stream), then in the **same** task
    /// `await recorder.stop()` first then `await recorder.start(deviceUID:)` -- ensuring start
    /// never reaches the actor before stop (otherwise start would throw `.alreadyRecording` and silently interrupt the test).
    private func restartTesting() {
        guard isTesting else { return }
        level = 0
        // Cancel the old for-await, yielding the single-consumer levels stream; stop/start are executed serially by the new task below.
        levelTask?.cancel()
        // Bump the generation so any in-flight write from the old (now cancelled) task is dropped after this zeroing.
        levelGeneration += 1
        // `selectedUID` is the live source of truth (kept in sync with config via its didSet).
        let deviceUID = selectedUID
        levelTask = makeLevelTask(deviceUID: deviceUID, stopFirst: true, generation: levelGeneration)
    }

    /// Called on leaving the page: ensures capture is stopped, to avoid the background occupying the microphone continuously.
    func onDisappear() {
        stopTesting()
    }
}
