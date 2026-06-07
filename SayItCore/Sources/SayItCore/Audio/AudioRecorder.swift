import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

/// 基于 `AVAudioEngine` 的麦克风录音实现。
///
/// 工作方式：
/// 1. `start()` 检查/请求麦克风权限；
/// 2. 每次 `start()` 都新建一个全新的 `AVAudioEngine`（关键：避免复用旧引擎缓存的坏 inputFormat）；
/// 3. 在新引擎的 `inputNode` 上安装 tap，按硬件原始格式抓取 PCM 缓冲；
/// 4. 用 `AVAudioConverter` 把每段缓冲转换到目标格式（16kHz / 单声道 / Float32）；
/// 5. 用 `FloatSampleAccumulator` 累积转换后的 Float 样本；
/// 6. `stop()` 拆 tap、停引擎并释放引擎，返回累积的 `[Float]`。
///
/// 重要：经真机定位，复用同一个长生命周期 `AVAudioEngine` 会触发经典坑——若 `inputNode`
/// 在麦克风权限授予之前被读取过，其 `inputFormat` 会缓存一个坏状态（0 声道 / 0Hz），
/// 之后即便权限已授予，复用该引擎仍只会拿到静音/空缓冲，导致电平恒为 0。因此本实现
/// 在每次录音开始时（权限确认之后）创建一个全新的引擎，录音结束时释放它。
///
/// 用 `actor` 保证录音状态与累积缓冲的并发安全。tap 回调运行在音频实时线程，
/// 其中只做“同步格式转换 + 把转换好的样本通过 Task 投递回 actor 累积”。
public actor AudioRecorder: AudioRecording {
    /// 当前录音会话使用的 AVAudioEngine。每次 `start()` 重建，`stop()` 释放。
    /// 经典坑：复用旧引擎会缓存坏 inputFormat（0ch/0Hz），导致静音采集。
    private var engine: AVAudioEngine?

    /// 目标输出格式：16kHz / 单声道 / Float32（非交错）。
    private let targetFormat: AVAudioFormat

    /// 累积转换后的样本。
    private var accumulator = FloatSampleAccumulator()

    /// 当前是否正在录音。
    private var recording = false

    /// tap 每次回调请求的帧数（缓冲大小）。值偏大可降低回调频率。
    private let tapBufferSize: AVAudioFrameCount

    /// 本次录音会话已捕获的原始输入帧总数（用于 stop() 时汇总日志）。
    private var capturedFrames: UInt64 = 0

    /// 用于查询的统一日志器（`log show --predicate 'subsystem == "com.liuwentong.SayIt"'`）。
    private nonisolated static let log = Logger(subsystem: "com.liuwentong.SayIt", category: "audio")

    /// 实时归一化输入电平流（0...1），供 HUD 波形消费。
    ///
    /// 关键：此流与其 continuation 在整个 `AudioRecorder` 生命周期内保持稳定，
    /// 跨多次 `start()`/`stop()`（即跨引擎重建）都复用同一个流；每次录音的 tap
    /// 把电平 yield 进同一个 continuation。绝不在录音会话间重建该流。
    public nonisolated let levels: AsyncStream<Double>
    private nonisolated let levelContinuation: AsyncStream<Double>.Continuation

    /// 初始化。`tapBufferSize` 为 inputNode tap 的缓冲帧数，默认 4096。
    public init(tapBufferSize: AVAudioFrameCount = 4096) {
        self.tapBufferSize = tapBufferSize
        var continuation: AsyncStream<Double>.Continuation!
        self.levels = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.levelContinuation = continuation
        // 目标格式：标准 Float32、给定采样率与单声道。非交错对单声道无差别。
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: AudioFormat.channelCount,
            interleaved: false
        ) else {
            // AVAudioFormat 对这组合法参数恒非 nil；构造失败属编程错误。
            fatalError("AudioRecorder: 无法创建目标 AVAudioFormat（16kHz/mono/Float32）")
        }
        self.targetFormat = format
    }

    deinit {
        levelContinuation.finish()
    }

    public var isRecording: Bool {
        recording
    }

    public func start(deviceUID: String? = nil) async throws {
        guard !recording else { throw AudioRecordingError.alreadyRecording }

        // 1) 权限：已授权直接过；未决定则请求；被拒/受限则报错。
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

        // 权限已确认：记录当前权限状态，便于真机日志比对。
        Self.log.notice("start(deviceUID: \(deviceUID ?? "nil", privacy: .public)): permission=\(String(describing: MicrophonePermission.current), privacy: .public)")

        accumulator.reset()
        capturedFrames = 0

        // 2) 关键：创建一个全新的 AVAudioEngine。绝不复用旧引擎（避免缓存的坏 inputFormat）。
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // 2.5) 选定设备：把 inputNode 底层 AudioUnit 绑定到该设备。
        //      deviceUID 为 nil（或解析不到设备）时不改动，沿用系统默认输入设备。
        //      必须在读取 inputFormat / 安装 tap 前完成——设备变了原始格式也可能变。
        if let deviceUID, let deviceID = AudioInputDeviceManager.deviceID(forUID: deviceUID) {
            Self.setCurrentInputDevice(deviceID, on: inputNode)
        }

        var workingEngine = engine
        var workingInputNode = inputNode
        var inputFormat = inputNode.inputFormat(forBus: 0)
        Self.log.notice("inputFormat: sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")

        // 3) 防御：坏格式（0 声道或 0Hz）会确证“复用引擎缓存坏 inputFormat”的假设。
        //    尝试一次恢复：丢弃当前引擎、重建一个新引擎再次查询。仍坏则记错并继续尝试启动。
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
                // 恢复成功：改用重建后的引擎。
                workingEngine = rebuilt
                workingInputNode = rebuiltInput
                inputFormat = recoveredFormat
            } else {
                Self.log.error("inputFormat still invalid after rebuild; proceeding with start attempt anyway")
            }
        }

        // 4) 安装 tap + 启动引擎（成功后保存引擎引用）。
        self.engine = workingEngine
        try installTapStartAndStore(
            engine: workingEngine,
            inputNode: workingInputNode,
            inputFormat: inputFormat
        )
        recording = true
    }

    /// 为给定引擎构建转换器、安装 tap 并启动。失败时清理引擎引用并抛错。
    ///
    /// 抽成实例方法是为了让“坏格式恢复路径”与“正常路径”复用同一段逻辑，
    /// 且能在 actor 隔离下直接清理 `engine`。
    private func installTapStartAndStore(
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat
    ) throws {
        let targetFormat = self.targetFormat
        let tapBufferSize = self.tapBufferSize
        let levelContinuation = self.levelContinuation

        // 构建从硬件格式到目标格式的转换器（处理采样率 + 声道下混 + 量化）。
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Self.log.error("AVAudioConverter creation FAILED (from sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public))")
            self.engine = nil
            throw AudioRecordingError.converterUnavailable
        }
        Self.log.notice("AVAudioConverter created: ok")

        // 安装 tap。回调在音频实时线程；这里同步把缓冲转换为目标格式并取出 Float 样本，
        // 再把 `[Float]`（Sendable）投递回 actor 累积——避免把非 Sendable 的
        // AVAudioPCMBuffer 跨隔离域传递引发数据竞争。
        // tapCounter：纯计数器，用于对实时线程日志限流（首个缓冲 + 之后每约 50 个）。
        nonisolated(unsafe) let tapCounter = TapCounter()
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLength = buffer.frameLength
            let samples = AudioRecorder.convertToSamples(buffer, using: converter, to: targetFormat) ?? []
            let level = AudioRecorder.normalizedLevel(samples)
            // 在实时线程同步算出归一化电平后立即投递（continuation 为 Sendable，仅留最新值）。
            levelContinuation.yield(level)

            // 限流日志：首个缓冲 + 之后每约 50 个，记录帧长/取出样本数/电平，便于真机定位静音采集。
            let n = tapCounter.next()
            if n == 1 || n % 50 == 0 {
                AudioRecorder.log.notice("tap#\(n, privacy: .public): frameLength=\(frameLength, privacy: .public) samples=\(samples.count, privacy: .public) level=\(level, privacy: .public)")
            }

            guard !samples.isEmpty else { return }
            Task { await self.ingest(samples, rawFrames: UInt64(frameLength)) }
        }

        // 启动引擎。
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
        // 释放本次会话的引擎：下次 start() 会重建一个全新引擎。
        engine = nil
        recording = false
        Self.log.notice("stop(): totalCapturedFrames=\(self.capturedFrames, privacy: .public) accumulatedSamples=\(self.accumulator.count, privacy: .public)")
        // 录音结束：把电平归零，让 HUD 波形平复（流本身保持有效以供下一次录音）。
        levelContinuation.yield(0)
        return accumulator.drain()
    }

    /// 把 `inputNode` 底层的输入 AudioUnit 当前设备设为给定 `AudioDeviceID`。
    ///
    /// 通过 `AVAudioInputNode.auAudioUnit.deviceID` 设置（等价于对底层 AudioUnit 写
    /// `kAudioOutputUnitProperty_CurrentDevice`，但走 AVAudioEngine 的封装，更稳妥）。
    /// 失败（抛错）时静默忽略：保持使用系统默认设备，不阻断录音启动。
    private nonisolated static func setCurrentInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) {
        do {
            try inputNode.auAudioUnit.setDeviceID(deviceID)
        } catch {
            // 绑定失败（设备忙/不兼容）：回落系统默认，录音仍可进行。
        }
    }

    /// 由一段 Float 样本算出归一化输入电平（0...1）。
    ///
    /// 流程：RMS → dBFS → 映射到 0...1（按 `minDb`...0dB 线性归一）。
    /// 用对数刻度更贴合人对响度的感知，避免低电平时波形几乎不动。
    nonisolated static func normalizedLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sumSquares = 0.0
        for sample in samples {
            let value = Double(sample)
            sumSquares += value * value
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        // dBFS：满量程（rms=1）为 0dB；越小越负。低于 minDb 视为静音。
        let minDb = -50.0
        let db = 20.0 * Foundation.log10(rms)
        guard db > minDb else { return 0 }
        let normalized = (db - minDb) / (0 - minDb)
        return Swift.min(Swift.max(normalized, 0), 1)
    }

    /// 把转换好的样本累积进来（actor 隔离，串行安全）。
    private func ingest(_ samples: [Float], rawFrames: UInt64) {
        // 录音已停止后到达的迟到样本直接丢弃，避免污染下一次录音。
        guard recording else { return }
        capturedFrames += rawFrames
        accumulator.append(contentsOf: samples)
    }

    /// 把一段输入缓冲转换为目标格式并取出 channel-0 的 Float 样本。失败/无数据返回 nil。
    ///
    /// 用 `AVAudioConverter` 的“按需供给”模式：转换器需要数据时回调返回整段输入缓冲。
    /// 输出缓冲容量按采样率比例 + 余量估算。返回 `[Float]`（Sendable），便于跨隔离域传递。
    private nonisolated static func convertToSamples(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> [Float]? {
        let inputFrames = Double(input.frameLength)
        guard inputFrames > 0 else { return nil }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        // 估算输出帧数，向上取整并加少量余量，避免容量不足截断。
        let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 16
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        // 用单元素引用盒持有“已供给”标志。AVAudioConverter 的输入块在 Swift overlay 中
        // 标注为 @Sendable，但它由 convert(...) 同步调用、无真实并发；故对捕获的
        // feedState 与 input 用 nonisolated(unsafe) 断言安全，消除误报的 Sendable 告警。
        nonisolated(unsafe) let feedState = FeedState()
        nonisolated(unsafe) let inputBuffer = input
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            // 整段输入只供给一次；之后报告无更多数据。
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
            // 有输出帧则取出；否则视为无数据。
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

/// `convertToSamples` 内部用的单字段引用盒，仅承载转换器输入块的“已供给”标志。
private final class FeedState {
    var fed = false
}

/// tap 回调日志限流用的计数器引用盒。tap 由音频实时线程串行调用，无真实并发；
/// 用 `nonisolated(unsafe)` 捕获，避免误报的 Sendable 告警。
private final class TapCounter {
    private var count: UInt64 = 0
    func next() -> UInt64 {
        count += 1
        return count
    }
}
