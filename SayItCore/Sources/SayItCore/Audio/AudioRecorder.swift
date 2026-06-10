import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

/// A microphone recording implementation based on `AVAudioEngine`.
///
/// How it works:
/// 1. `start()` checks/requests microphone permission;
/// 2. each `start()` creates a brand-new `AVAudioEngine` (key: avoiding reusing the bad inputFormat cached by an old engine);
/// 3. installs a tap on the new engine's `inputNode`, capturing PCM buffers in the hardware's raw format;
/// 4. converts each buffer to the target format (16kHz / mono / Float32) with `AVAudioConverter`;
/// 5. accumulates the converted Float samples with `FloatSampleAccumulator`;
/// 6. `stop()` removes the tap, stops and releases the engine, returning the accumulated `[Float]`.
///
/// Important: as pinned down on real devices, reusing the same long-lived `AVAudioEngine` triggers a classic pitfall -- if `inputNode`
/// is read before microphone permission is granted, its `inputFormat` caches a bad state (0 channels / 0Hz),
/// and afterwards, even with permission granted, reusing that engine still only yields silent/empty buffers, causing the level to stay at 0. So this implementation
/// creates a brand-new engine at the start of each recording (after permission is confirmed) and releases it when recording ends.
///
/// Uses an `actor` to guarantee concurrency safety of the recording state and accumulation buffer. The tap callback runs on the audio real-time thread,
/// where it only does "synchronous format conversion + delivering the converted samples back to the actor for accumulation via a Task".
public actor AudioRecorder: AudioRecording {
    /// Backing storage for the current recording session's `AVAudioEngine`, held in a `Sendable` box so it
    /// is reachable from the `nonisolated` `deinit` (which cannot touch actor-isolated, non-Sendable state
    /// under Swift 6) for off-actor teardown. Mirrors the `nonisolated(unsafe)` box style already used in
    /// this file. All in-session reads/writes still go through the actor-isolated `engine` accessor below,
    /// so the actor serializes start/stop and the stored reference is never touched concurrently.
    private nonisolated let engineHolder = EngineHolder()

    /// The AVAudioEngine used by the current recording session. Rebuilt on each `start()`, released on `stop()`.
    /// Classic pitfall: reusing an old engine caches a bad inputFormat (0ch/0Hz), causing silent capture.
    private var engine: AVAudioEngine? {
        get { engineHolder.engine }
        set { engineHolder.engine = newValue }
    }

    /// The target output format: 16kHz / mono / Float32 (non-interleaved).
    private let targetFormat: AVAudioFormat

    /// Accumulates the converted samples.
    private var accumulator = FloatSampleAccumulator()

    /// Whether currently recording.
    private var recording = false

    /// The number of frames requested per tap callback (buffer size). A larger value lowers the callback frequency.
    private let tapBufferSize: AVAudioFrameCount

    /// Per-session funnel that serializes tap-delivered samples into a single ordered ingest pipeline.
    ///
    /// Why: the realtime tap runs on the audio real-time thread and must hand its `[Float]` (Sendable) samples back to
    /// the actor for accumulation. Spawning one unstructured `Task { await ingest(...) }` PER buffer is both unbounded
    /// (a burst spawns unbounded concurrent tasks) and out-of-order (independent unstructured tasks acquire the actor
    /// in unspecified order, so samples can be appended out of capture order). Instead the tap `yield`s into this
    /// `AsyncStream` and a single draining task (``ingestDrainTask``) consumes it FIFO -- so there is at most ONE
    /// in-flight ingest and buffer order is preserved.
    private nonisolated let ingestPipeline = IngestPipelineHolder()

    /// The single task draining ``ingestPipeline`` for the current session, calling `ingest(_:rawFrames:)` serially in
    /// FIFO order. Rebuilt on each `start()` (alongside the per-session stream); torn down on `stop()` / failed start.
    private var ingestDrainTask: Task<Void, Never>?

    /// The total raw input frames captured in this recording session (for the summary log on stop()).
    private var capturedFrames: UInt64 = 0

    /// The unified logger used for querying (`log show --predicate 'subsystem == "com.liuwentong.SayIt"'`).
    private nonisolated static let log = Logger(subsystem: SayItCore.identifier, category: "audio")

    /// The real-time level stream holder (stream + continuation) for each recording session, rebuildable across sessions.
    ///
    /// Key fix: `AsyncStream` is a "single-consumer" stream -- once its consuming iteration is cancelled/ended
    /// (HUD/MicTest's `levelTask?.cancel()` in `stopTesting()` finishes the stream),
    /// that same stream ends permanently, and a second test reading the same stream afterwards immediately gets end and a zero level,
    /// manifesting as "green bars on the first test, no green bars on the retest". So each `start()` rebuilds a brand-new pair of
    /// stream + continuation; the consumer reads `recorder.levels` after `start()` (both MicTest/HUD
    /// do so), getting this session's new stream. `stop()` ends this session's continuation.
    private nonisolated let levelStream = LevelStreamHolder()

    /// The real-time normalized input level stream (0...1), for the HUD waveform to consume.
    ///
    /// Each recording session (`start()`) rebuilds a brand-new stream; be sure to read it after `start()`,
    /// to get the current session's stream. After recording stops the stream ends, and the next `start()` gives a new stream again.
    public nonisolated var levels: AsyncStream<Double> {
        levelStream.currentStream
    }

    /// Initialization. `tapBufferSize` is the inputNode tap's buffer frame count, defaults to 4096.
    public init(tapBufferSize: AVAudioFrameCount = 4096) {
        self.tapBufferSize = tapBufferSize
        // Target format: standard Float32, with the given sample rate and mono. Non-interleaved makes no difference for mono.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: AudioFormat.channelCount,
            interleaved: false
        ) else {
            // AVAudioFormat is always non-nil for this set of legal parameters; a construction failure is a programming error.
            fatalError("AudioRecorder: 无法创建目标 AVAudioFormat（16kHz/mono/Float32）")
        }
        self.targetFormat = format
    }

    deinit {
        // Actor deinit is nonisolated; AVAudioEngine teardown is safe off-actor. A recorder dropped
        // mid-session must not leave the mic/input device live, so reach the engine through the
        // nonisolated holder and mirror stop()'s teardown order (removeTap then stop) before releasing it.
        if let engine = engineHolder.engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        levelStream.finishCurrent()
        // Finish the ingest pipeline too: the draining task captures `self` weakly (so it never kept us alive), and
        // finishing its stream lets that now-orphaned task exit promptly instead of hanging on a never-finished stream.
        ingestPipeline.endSession()
    }

    public var isRecording: Bool {
        recording
    }

    // MARK: - Test seams (only @testable-visible, the public API is unchanged)

    /// For testing: simulates the level-stream rebuild at the start of a recording session (same source as `beginSession()` inside `start()`).
    /// Lets unit tests reproduce the real "cross-session stream reuse" lifecycle without microphone permission/hardware.
    nonisolated func beginLevelSessionForTesting() {
        levelStream.beginSession()
    }

    /// For testing: simulates a tap delivering a normalized level into the current session's stream (same source as a real tap's `yield`,
    /// the real tap also runs on the audio real-time thread outside the actor).
    nonisolated func emitLevelForTesting(_ level: Double) {
        levelStream.currentContinuation.yield(level)
    }

    /// For testing: simulates the level-stream wrap-up at the end of a recording session (same source as `endSession()` inside `stop()`).
    nonisolated func endLevelSessionForTesting() {
        levelStream.endSession()
    }

    /// For testing: begins an ingest "session" without microphone permission/hardware -- flips `recording` on (so
    /// `ingest(_:rawFrames:)` does not discard the samples as late) and rebuilds + starts the single draining task
    /// (same source as `startIngestDrain()` inside `start()`). Lets unit tests drive the realtime-tap -> ingest funnel.
    func beginIngestSessionForTesting() {
        recording = true
        startIngestDrain()
    }

    /// For testing: enqueues one ingest item into the current session's pipeline, exactly as the realtime tap does
    /// (`ingestPipeline.currentContinuation.yield(...)` from off the actor). Ordering/single-flight is then exercised
    /// by the single draining task started above.
    nonisolated func emitIngestForTesting(_ samples: [Float], rawFrames: UInt64) {
        ingestPipeline.currentContinuation.yield(IngestItem(samples: samples, rawFrames: rawFrames))
    }

    /// For testing: finishes the ingest pipeline and awaits the draining task to fully process the buffered items
    /// (same source as `endIngestDrain()` inside `stop()`), so a test can assert the accumulated result afterwards.
    func endIngestSessionForTesting() async {
        await endIngestDrain()
        recording = false
    }

    /// For testing: the channel-0 Float samples accumulated so far (via `ingest(_:rawFrames:)`), to assert the funnel
    /// delivered every buffer in capture order.
    var accumulatedSamplesForTesting: [Float] { accumulator.samples }

    /// For testing: the number of raw frames accumulated so far (via `ingest(_:rawFrames:)`), to assert the funnel
    /// delivered every buffer.
    var capturedFramesForTesting: UInt64 { capturedFrames }

    /// For testing: sets up an "as-if a start had marked us recording" state, then runs the REAL engine.start()-failure
    /// cleanup (`resetStateAfterStartFailure()`, the same helper the `catch` invokes) and returns the resulting
    /// `recording` flag. Locks the "a failed start resets `isRecording`" guarantee without microphone permission/hardware.
    func recordingAfterStartFailureCleanupForTesting() -> Bool {
        recording = true
        resetStateAfterStartFailure()
        return recording
    }

    public func start(deviceUID: String? = nil) async throws {
        guard !recording else { throw AudioRecordingError.alreadyRecording }

        // 1) Permission: pass directly if authorized; request if undetermined; error if denied/restricted.
        switch MicrophonePermission.current {
        case .authorized:
            break
        case .notDetermined:
            guard await MicrophonePermission.request() else {
                throw AudioRecordingError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw AudioRecordingError.microphonePermissionDenied
        }

        // Permission confirmed: record the current permission status, for easy comparison in on-device logs.
        Self.log.notice("start(deviceUID: \(deviceUID ?? "nil", privacy: .public)): permission=\(String(describing: MicrophonePermission.current), privacy: .public)")

        accumulator.reset()
        capturedFrames = 0

        // 1.5) Key fix: rebuild a brand-new pair of level stream + continuation for this session.
        //      `AsyncStream` is single-consumer -- the previous session's consuming task being cancelled ends the old stream permanently,
        //      and reusing the old stream causes "no green bars on the retest". The consumer reads `levels` after `start()`,
        //      so rebuild here first, ensuring they get this session's new stream.
        levelStream.beginSession()

        // 1.6) Rebuild this session's ingest pipeline and spin up the SINGLE draining task that serializes the
        //      tap-delivered samples (at most one in-flight ingest, FIFO order). The tap `yield`s into the pipeline
        //      instead of spawning an unstructured `Task` per buffer (unbounded + out-of-order). The drain task ends
        //      naturally when the pipeline's continuation is finished (in `stop()` / the failure catch / `deinit`).
        startIngestDrain()

        // Pair the level-stream lifecycle with the engine lifecycle: any failure after beginSession()
        // (converterUnavailable / engineStartFailed / the invalid-format fast-fail below / any AVFoundation throw)
        // must tear down this session's level stream so no orphaned live-but-dead stream is left behind.
        // The success path is behavior-identical (a do/catch with re-throw is transparent when nothing throws).
        do {
            // 2) Key: create a brand-new AVAudioEngine. Never reuse the old engine (avoiding the cached bad inputFormat).
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode

            // 2.5) Selected device: bind the inputNode's underlying AudioUnit to that device.
            //      When deviceUID is nil (or no device resolves), leave it unchanged, using the system default input device.
            //      Must be done before reading inputFormat / installing the tap -- when the device changes the raw format may change too.
            if let deviceUID, let deviceID = AudioInputDeviceManager.deviceID(forUID: deviceUID) {
                Self.setCurrentInputDevice(deviceID, on: inputNode)
            }

            var workingEngine = engine
            var workingInputNode = inputNode
            var inputFormat = inputNode.inputFormat(forBus: 0)
            Self.log.notice("inputFormat: sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")

            // 3) Defense: a bad format (0 channels or 0Hz) would confirm the hypothesis of "reusing the engine caches a bad inputFormat".
            //    Try one recovery: discard the current engine, rebuild a new engine and query again. If still bad, fail fast.
            if inputFormat.channelCount == 0 || inputFormat.sampleRate == 0 {
                Self.log.error("inputFormat invalid (channels=\(inputFormat.channelCount, privacy: .public), sampleRate=\(inputFormat.sampleRate, privacy: .public)); attempting one engine rebuild to recover")
                let rebuilt = AVAudioEngine()
                let rebuiltInput = rebuilt.inputNode
                if let deviceUID, let deviceID = AudioInputDeviceManager.deviceID(forUID: deviceUID) {
                    Self.setCurrentInputDevice(deviceID, on: rebuiltInput)
                }
                let recoveredFormat = rebuiltInput.inputFormat(forBus: 0)
                Self.log.notice("rebuilt inputFormat: sampleRate=\(recoveredFormat.sampleRate, privacy: .public) channels=\(recoveredFormat.channelCount, privacy: .public)")
                if recoveredFormat.channelCount != 0, recoveredFormat.sampleRate != 0 {
                    // Recovery succeeded: switch to the rebuilt engine.
                    workingEngine = rebuilt
                    workingInputNode = rebuiltInput
                    inputFormat = recoveredFormat
                } else {
                    // Fast-fail: handing a degenerate 0ch/0Hz format to AVAudioConverter/installTap can raise an
                    // uncatchable AVFoundation NSException. Throw instead; the do/catch above tears down the level
                    // stream and self.engine stays nil (it is only assigned after this branch), leaving a clean failed-start state.
                    Self.log.error("inputFormat still invalid after rebuild (0ch/0Hz); failing fast instead of feeding a degenerate format to AVAudioConverter/installTap")
                    throw AudioRecordingError.engineStartFailed("invalid input format 0ch/0Hz")
                }
            }

            // 4) Install the tap + start the engine (save the engine reference on success).
            self.engine = workingEngine
            try installTapStartAndStore(
                engine: workingEngine,
                inputNode: workingInputNode,
                inputFormat: inputFormat
            )
            recording = true
        } catch {
            // installTapStartAndStore already nils self.engine on its own throw paths (incl. resetting `recording`),
            // and the fast-fail above throws before self.engine is assigned, so the catch only needs to tear down
            // the per-session streams (touching self.engine here would conflict with the existing engine-cleanup
            // contract). Tear down BOTH this session's level stream and its ingest pipeline + draining task so a
            // failed start leaves no orphaned live-but-dead stream / lingering drain task behind. Re-throw unchanged.
            levelStream.endSession()
            await endIngestDrain()
            throw error
        }
    }

    /// Builds a converter for the given engine, installs the tap and starts it. On failure, cleans up the engine reference and throws.
    ///
    /// Extracted into an instance method so the "bad-format recovery path" and "normal path" reuse the same logic,
    /// and so `engine` can be cleaned up directly under actor isolation.
    private func installTapStartAndStore(
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat
    ) throws {
        let targetFormat = self.targetFormat
        let tapBufferSize = self.tapBufferSize
        // Capture this session's continuation snapshot: the tap always delivers levels into the stream "rebuilt by this start()",
        // so even if start() later rebuilds a new stream, the old tap will not wrongly deliver to the new session.
        let levelContinuation = levelStream.currentContinuation
        // Likewise capture this session's ingest continuation: the tap funnels every buffer's samples into the SINGLE
        // draining pipeline rebuilt by this start(), preserving order and bounding concurrency to one in-flight ingest.
        let ingestContinuation = ingestPipeline.currentContinuation

        // Build the converter from the hardware format to the target format (handling sample rate + channel down-mix + quantization).
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Self.log.error("AVAudioConverter creation FAILED (from sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public))")
            self.engine = nil
            throw AudioRecordingError.converterUnavailable
        }
        Self.log.notice("AVAudioConverter created: ok")

        // Install the tap. The callback is on the audio real-time thread; here it synchronously converts the buffer to the target format and extracts the Float samples,
        // then delivers the `[Float]` (Sendable) back to the actor for accumulation -- avoiding passing the non-Sendable
        // AVAudioPCMBuffer across isolation domains, which would cause a data race.
        // tapCounter: a pure counter, used to rate-limit real-time-thread logs (the first buffer + about every 50 thereafter).
        nonisolated(unsafe) let tapCounter = TapCounter()
        // The converter is built once here and is then used ONLY by the realtime tap closure below, which runs
        // serially on the single audio real-time thread (no concurrent calls). It is bound to an explicit local
        // before capture to make that single-realtime-thread ownership transfer auditable, mirroring the
        // FeedState/TapCounter pattern in this file. (On this SDK AVAudioConverter is Sendable, so no
        // nonisolated(unsafe) box is required; the explicit binding documents the realtime-only usage.)
        let realtimeConverter = converter
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLength = buffer.frameLength
            let samples = AudioRecorder.convertToSamples(buffer, using: realtimeConverter, to: targetFormat) ?? []
            let level = AudioRecorder.normalizedLevel(samples)
            // After synchronously computing the normalized level on the real-time thread, deliver it immediately (the continuation is Sendable, keeping only the latest value).
            levelContinuation.yield(level)

            // Rate-limited logging: the first buffer + about every 50 thereafter, logging the frame length/extracted sample count/level, for easy on-device pinpointing of silent capture.
            let n = tapCounter.next()
            if n == 1 || n % 50 == 0 {
                AudioRecorder.log.notice("tap#\(n, privacy: .public): frameLength=\(frameLength, privacy: .public) samples=\(samples.count, privacy: .public) level=\(level, privacy: .public)")
            }

            guard !samples.isEmpty else { return }
            // Funnel the samples into this session's ingest pipeline rather than spawning one unstructured
            // `Task { await self.ingest(...) }` per buffer (unbounded concurrent ingests + out-of-order appends).
            // The single draining task started in `start()` consumes the pipeline FIFO, so there is at most one
            // in-flight ingest and capture order is preserved.
            ingestContinuation.yield(IngestItem(samples: samples, rawFrames: UInt64(frameLength)))
        }

        // Start the engine.
        engine.prepare()
        do {
            try engine.start()
            Self.log.notice("engine.start(): success")
        } catch {
            Self.log.error("engine.start() FAILED: \(error.localizedDescription, privacy: .public)")
            inputNode.removeTap(onBus: 0)
            resetStateAfterStartFailure()
            throw AudioRecordingError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Resets the actor state left by a failed `engine.start()` (the caller already removed the tap): release the
    /// engine and clear `recording`. `recording` is only set to `true` by `start()` AFTER `installTapStartAndStore`
    /// returns, but resetting it here makes the failure cleanup self-contained (mirrors the engine teardown) and robust
    /// to any future reordering of the `recording = true` assignment, so a failed start always leaves clean state.
    private func resetStateAfterStartFailure() {
        self.engine = nil
        self.recording = false
    }

    /// Rebuilds the per-session ingest pipeline and starts the SINGLE draining task that serializes tap-delivered
    /// samples (at most one in-flight ingest, FIFO order). Replaces any prior session's task (it should already have
    /// ended via `endIngestDrain()`, but cancel defensively). `self` is captured weakly so the running task never
    /// keeps the actor alive past its last external reference (the task ends when the continuation is finished).
    private func startIngestDrain() {
        ingestDrainTask?.cancel()
        let stream = ingestPipeline.beginSession()
        ingestDrainTask = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                await self.ingest(item.samples, rawFrames: item.rawFrames)
            }
        }
    }

    /// Finishes the current session's ingest pipeline and awaits the draining task, so every buffer the tap already
    /// handed off is accumulated before `stop()` drains the result (or the failed-start cleanup completes).
    private func endIngestDrain() async {
        ingestPipeline.endSession()
        await ingestDrainTask?.value
        ingestDrainTask = nil
    }

    @discardableResult
    public func stop() async throws -> [Float] {
        guard recording else { throw AudioRecordingError.notRecording }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Release this session's engine: the next start() rebuilds a brand-new engine.
        engine = nil
        recording = false
        // Finish this session's ingest pipeline + await the single draining task to fully process any buffered
        // samples already handed off by the tap, so they are accumulated before drain() reads the result below.
        await endIngestDrain()
        Self.log.notice("stop(): totalCapturedFrames=\(self.capturedFrames, privacy: .public) accumulatedSamples=\(self.accumulator.count, privacy: .public)")
        // Recording ended: first zero the level to settle the HUD waveform, then end this session's stream.
        // The next `start()` rebuilds a brand-new stream; the consumer just re-reads `levels` at that point.
        levelStream.endSession()
        return accumulator.drain()
    }

    /// Sets the current device of `inputNode`'s underlying input AudioUnit to the given `AudioDeviceID`.
    ///
    /// Set via `AVAudioInputNode.auAudioUnit.deviceID` (equivalent to writing `kAudioOutputUnitProperty_CurrentDevice` to the underlying AudioUnit,
    /// but going through AVAudioEngine's wrapper, more robust).
    /// On failure (a throw) silently ignore: keep using the system default device, not blocking recording start.
    private nonisolated static func setCurrentInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) {
        do {
            try inputNode.auAudioUnit.setDeviceID(deviceID)
        } catch {
            // Binding failed (device busy/incompatible): fall back to the system default, recording can still proceed.
        }
    }

    /// Computes a normalized input level (0...1) from a segment of Float samples.
    ///
    /// Flow: RMS -> dBFS -> mapped to 0...1 (linearly normalized over `minDb`...0dB).
    /// Uses a logarithmic scale to better match human loudness perception, avoiding the waveform barely moving at low levels.
    nonisolated static func normalizedLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sumSquares = 0.0
        for sample in samples {
            let value = Double(sample)
            sumSquares += value * value
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        // dBFS: full scale (rms=1) is 0dB; smaller is more negative. Below minDb is treated as silence.
        let minDb = -50.0
        let db = 20.0 * Foundation.log10(rms)
        guard db > minDb else { return 0 }
        let normalized = (db - minDb) / (0 - minDb)
        return Swift.min(Swift.max(normalized, 0), 1)
    }

    /// Accumulates the converted samples (actor-isolated, serially safe).
    private func ingest(_ samples: [Float], rawFrames: UInt64) {
        // Late samples arriving after recording has stopped are discarded directly, to avoid polluting the next recording.
        guard recording else { return }
        capturedFrames += rawFrames
        accumulator.append(contentsOf: samples)
    }

    /// Converts a segment of input buffer to the target format and extracts the channel-0 Float samples. Returns nil on failure/no data.
    ///
    /// Uses `AVAudioConverter`'s "supply-on-demand" mode: when the converter needs data, the callback returns the whole input buffer.
    /// The output buffer capacity is estimated by the sample-rate ratio + headroom. Returns `[Float]` (Sendable), for easy passing across isolation domains.
    private nonisolated static func convertToSamples(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> [Float]? {
        let inputFrames = Double(input.frameLength)
        guard inputFrames > 0 else { return nil }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        // Estimate the output frame count, rounding up and adding a small headroom, to avoid truncation from insufficient capacity.
        let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 16
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        // Use a single-element reference box to hold the "already supplied" flag. AVAudioConverter's input block is
        // annotated @Sendable in the Swift overlay, but it is called synchronously by convert(...) with no real concurrency; so for the captured
        // feedState and input we assert safety with nonisolated(unsafe), eliminating the false-positive Sendable warning.
        nonisolated(unsafe) let feedState = FeedState()
        nonisolated(unsafe) let inputBuffer = input
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            // The whole input is supplied only once; afterwards report no more data.
            if feedState.fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            feedState.fed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            // If there are output frames, extract them; otherwise treat it as no data.
            guard output.frameLength > 0, let channelData = output.floatChannelData else { return nil }
            let count = Int(output.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: count))
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }
}

/// A single-field reference box used inside `convertToSamples`, only carrying the converter input block's "already supplied" flag.
private final class FeedState {
    var fed = false
}

/// A counter reference box used for rate-limiting the tap callback logs. The tap is called serially by the audio real-time thread, with no real concurrency;
/// captured with `nonisolated(unsafe)`, to avoid the false-positive Sendable warning.
private final class TapCounter {
    private var count: UInt64 = 0
    func next() -> UInt64 {
        count += 1
        return count
    }
}

/// A `Sendable` box holding the current session's `AVAudioEngine`.
///
/// Why it is needed: `AudioRecorder.deinit` is `nonisolated` (actor deinits cannot be actor-isolated on
/// macOS < 15.4), so it cannot read the actor-isolated, non-Sendable engine directly under Swift 6 strict
/// concurrency. Routing the engine through this holder lets the deinit reach it for safe off-actor teardown
/// (a recorder dropped mid-session must stop the mic/input device).
///
/// Concurrency safety: every in-session read/write goes through `AudioRecorder`'s actor-isolated `engine`
/// accessor, so the actor serializes all access while the recorder is alive; the deinit only runs once the
/// actor is no longer reachable (no concurrent actor method can run during deinit). The single stored
/// reference is therefore never touched concurrently, so it is held with `nonisolated(unsafe)` and the box
/// is `@unchecked Sendable` -- the same single-owner-thread escape-hatch style as the `nonisolated(unsafe)`
/// boxes (`FeedState`/`TapCounter`) used elsewhere in this file.
private final class EngineHolder: @unchecked Sendable {
    nonisolated(unsafe) var engine: AVAudioEngine?
}

/// One unit of work handed from the realtime tap to the actor's ingest pipeline: the converted channel-0 Float
/// samples plus the raw input frame count for this buffer. `[Float]`/`UInt64` are Sendable, so funneling this struct
/// across the isolation boundary (tap thread -> draining task -> actor) never moves the non-Sendable AVAudioPCMBuffer.
private struct IngestItem: Sendable {
    let samples: [Float]
    let rawFrames: UInt64
}

/// A "per-session rebuildable" ingest pipeline holder.
///
/// Why it is needed: the realtime tap must hand each buffer's samples back to the actor for accumulation. Spawning one
/// unstructured `Task { await ingest(...) }` PER buffer is unbounded (a burst spawns unbounded concurrent ingests) and
/// out-of-order (independent unstructured tasks acquire the actor in unspecified order). This holder funnels the tap's
/// items into a single `AsyncStream` that ONE draining task consumes FIFO, so there is at most one in-flight ingest and
/// capture order is preserved. Mirrors ``LevelStreamHolder``'s lock-guarded, per-`start()`-rebuildable stream pattern,
/// but buffers `.unbounded` (audio samples must never be dropped, unlike the keep-latest level stream).
///
/// Concurrency safety: an `OSAllocatedUnfairLock` (`Sendable`) guards the stream/continuation pair, so the tap (off
/// actor) and the actor methods (`start`/`stop`) read/write it safely from any context.
private final class IngestPipelineHolder: Sendable {
    private struct Pair {
        var stream: AsyncStream<IngestItem>
        var continuation: AsyncStream<IngestItem>.Continuation
    }

    private let lock: OSAllocatedUnfairLock<Pair>

    init() {
        lock = OSAllocatedUnfairLock(initialState: Self.makePair())
    }

    /// Constructs a brand-new pair of unbounded ingest stream + continuation (audio must never be dropped).
    private static func makePair() -> Pair {
        var continuation: AsyncStream<IngestItem>.Continuation!
        let stream = AsyncStream<IngestItem>(bufferingPolicy: .unbounded) { continuation = $0 }
        return Pair(stream: stream, continuation: continuation)
    }

    /// The current session's continuation (for the tap to deliver items).
    var currentContinuation: AsyncStream<IngestItem>.Continuation {
        lock.withLock { $0.continuation }
    }

    /// Start a new session: finish the old stream (its draining task ends) and swap in a brand-new pair, returning the
    /// new stream so the caller can spin up this session's single draining task on it.
    func beginSession() -> AsyncStream<IngestItem> {
        lock.withLock { pair in
            pair.continuation.finish()
            pair = Self.makePair()
            return pair.stream
        }
    }

    /// End the current session: finish the stream so its draining task drains the remaining buffered items then exits.
    func endSession() {
        lock.withLock { $0.continuation.finish() }
    }
}

/// A "per-session rebuildable" level stream holder.
///
/// Why it is needed: `AudioRecorder.levels` is a `nonisolated` synchronous read-only property in the protocol,
/// which must be readable without entering the actor to get "the current session's stream"; and that stream must also be replaceable wholesale on each `start()`
/// with a brand-new pair of `AsyncStream` + `Continuation`. This holder uses
/// `OSAllocatedUnfairLock` (`Sendable`) to guard this pair of values, for safe read/write from a `nonisolated` context.
///
/// The root cause it fixes: `AsyncStream` is a single-consumer stream -- once its sole consuming iteration is cancelled/ended, the whole stream
/// finishes permanently; reusing the same stream means the second test gets no levels (the green bars no longer appear). Each
/// `beginSession()` swaps in a brand-new pair of streams, thoroughly avoiding that pitfall.
private final class LevelStreamHolder: Sendable {
    private struct Pair {
        var stream: AsyncStream<Double>
        var continuation: AsyncStream<Double>.Continuation
    }

    private let lock: OSAllocatedUnfairLock<Pair>

    init() {
        lock = OSAllocatedUnfairLock(initialState: Self.makePair())
    }

    /// Constructs a brand-new pair of "keep latest value only" level stream + continuation.
    private static func makePair() -> Pair {
        var continuation: AsyncStream<Double>.Continuation!
        let stream = AsyncStream<Double>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        return Pair(stream: stream, continuation: continuation)
    }

    /// The current session's level stream (for `AudioRecorder.levels` to read after `start()`).
    var currentStream: AsyncStream<Double> {
        lock.withLock { $0.stream }
    }

    /// The current session's continuation (for the tap to deliver levels).
    var currentContinuation: AsyncStream<Double>.Continuation {
        lock.withLock { $0.continuation }
    }

    /// Start a new session: end the old stream and swap in a brand-new pair of streams + continuation.
    /// Called by `start()` before rebuilding the engine; the consumer then reads `levels` to get the new stream.
    func beginSession() {
        lock.withLock { pair in
            pair.continuation.finish()
            pair = Self.makePair()
        }
    }

    /// End the current session: first zero the level to settle the waveform, then end this session's stream.
    func endSession() {
        lock.withLock { pair in
            pair.continuation.yield(0)
            pair.continuation.finish()
        }
    }

    /// End the current session's stream (used in `deinit`).
    func finishCurrent() {
        lock.withLock { $0.continuation.finish() }
    }
}
