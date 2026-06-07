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
    /// The AVAudioEngine used by the current recording session. Rebuilt on each `start()`, released on `stop()`.
    /// Classic pitfall: reusing an old engine caches a bad inputFormat (0ch/0Hz), causing silent capture.
    private var engine: AVAudioEngine?

    /// The target output format: 16kHz / mono / Float32 (non-interleaved).
    private let targetFormat: AVAudioFormat

    /// Accumulates the converted samples.
    private var accumulator = FloatSampleAccumulator()

    /// Whether currently recording.
    private var recording = false

    /// The number of frames requested per tap callback (buffer size). A larger value lowers the callback frequency.
    private let tapBufferSize: AVAudioFrameCount

    /// The total raw input frames captured in this recording session (for the summary log on stop()).
    private var capturedFrames: UInt64 = 0

    /// The unified logger used for querying (`log show --predicate 'subsystem == "com.liuwentong.SayIt"'`).
    private nonisolated static let log = Logger(subsystem: "com.liuwentong.SayIt", category: "audio")

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
        levelStream.finishCurrent()
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
        //    Try one recovery: discard the current engine, rebuild a new engine and query again. If still bad, log an error and continue trying to start.
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
                Self.log.error("inputFormat still invalid after rebuild; proceeding with start attempt anyway")
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
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLength = buffer.frameLength
            let samples = AudioRecorder.convertToSamples(buffer, using: converter, to: targetFormat) ?? []
            let level = AudioRecorder.normalizedLevel(samples)
            // After synchronously computing the normalized level on the real-time thread, deliver it immediately (the continuation is Sendable, keeping only the latest value).
            levelContinuation.yield(level)

            // Rate-limited logging: the first buffer + about every 50 thereafter, logging the frame length/extracted sample count/level, for easy on-device pinpointing of silent capture.
            let n = tapCounter.next()
            if n == 1 || n % 50 == 0 {
                AudioRecorder.log.notice("tap#\(n, privacy: .public): frameLength=\(frameLength, privacy: .public) samples=\(samples.count, privacy: .public) level=\(level, privacy: .public)")
            }

            guard !samples.isEmpty else { return }
            Task { await self.ingest(samples, rawFrames: UInt64(frameLength)) }
        }

        // Start the engine.
        engine.prepare()
        do {
            try engine.start()
            Self.log.notice("engine.start(): success")
        } catch {
            Self.log.error("engine.start() FAILED: \(error.localizedDescription, privacy: .public)")
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            throw AudioRecordingError.engineStartFailed(error.localizedDescription)
        }
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
