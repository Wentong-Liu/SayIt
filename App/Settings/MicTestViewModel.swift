import Observation
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

    /// The selectable input device list (with the "System Default" option presented separately by the UI).
    private(set) var devices: [AudioInputDevice] = []

    /// The system's current default input device UID (used to annotate "(System Default)" in the dropdown).
    private(set) var systemDefaultUID: String?

    /// Whether a microphone test capture is in progress.
    private(set) var isTesting: Bool = false

    /// The latest normalized input level (0...1), for the level bar to bind. Returns to 0 after stopping.
    private(set) var level: Double = 0

    /// The device UID selected in the UI; `nil` means "System Default".
    /// The setter writes back to ``AppConfig/inputDeviceUID``; if a test is in progress it restarts capture with the new device.
    var selectedUID: String? {
        get { config.inputDeviceUID }
        set {
            config.inputDeviceUID = newValue
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
        let deviceUID = config.inputDeviceUID
        levelTask = makeLevelTask(deviceUID: deviceUID, stopFirst: false)
    }

    /// Constructs the capture task: optionally `stop()` first (for switching the device on restart), then `start(deviceUID:)`,
    /// then serially consumes the level stream in the same task -- guaranteeing stop always reaches the actor before start.
    ///
    /// Note: ``AudioRecorder/levels`` is a single-consumer stream,
    /// only one task should `for await` it at a time; here this is guaranteed by cancelling the old task before building a new one.
    private func makeLevelTask(deviceUID: String?, stopFirst: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            if stopFirst {
                // Stop the old capture first: when not recording it throws .notRecording, which is just ignored in the device-switch scenario.
                _ = try? await self.recorder.stop()
            }
            do {
                try await self.recorder.start(deviceUID: deviceUID)
            } catch {
                // Start failure (no permission/device busy): reset the state, zero the level.
                await MainActor.run {
                    self.isTesting = false
                    self.level = 0
                }
                return
            }
            // Subscribe to the level stream; switch the normalized value back to MainActor to update the UI. The stream produces 0 after stop() and stays valid.
            for await value in self.recorder.levels {
                if Task.isCancelled { break }
                await MainActor.run { self.level = value }
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
        let deviceUID = config.inputDeviceUID
        levelTask = makeLevelTask(deviceUID: deviceUID, stopFirst: true)
    }

    /// Called on leaving the page: ensures capture is stopped, to avoid the background occupying the microphone continuously.
    func onDisappear() {
        stopTesting()
    }
}
