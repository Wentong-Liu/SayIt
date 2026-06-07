import AVFoundation
import Foundation

/// 基于 `AVAudioEngine` 的麦克风录音实现。
///
/// 工作方式：
/// 1. `start()` 检查/请求麦克风权限；
/// 2. 在 `inputNode` 上安装 tap，按硬件原始格式抓取 PCM 缓冲；
/// 3. 用 `AVAudioConverter` 把每段缓冲转换到目标格式（16kHz / 单声道 / Float32）；
/// 4. 用 `FloatSampleAccumulator` 累积转换后的 Float 样本；
/// 5. `stop()` 拆 tap、停引擎，返回累积的 `[Float]`。
///
/// 用 `actor` 保证录音状态与累积缓冲的并发安全。tap 回调运行在音频实时线程，
/// 其中只做“同步格式转换 + 把转换好的样本通过 Task 投递回 actor 累积”。
public actor AudioRecorder: AudioRecording {
    /// AVAudioEngine 实例。tap 安装在它的 inputNode 上。
    private let engine = AVAudioEngine()

    /// 目标输出格式：16kHz / 单声道 / Float32（非交错）。
    private let targetFormat: AVAudioFormat

    /// 累积转换后的样本。
    private var accumulator = FloatSampleAccumulator()

    /// 当前是否正在录音。
    private var recording = false

    /// tap 每次回调请求的帧数（缓冲大小）。值偏大可降低回调频率。
    private let tapBufferSize: AVAudioFrameCount

    /// 实时归一化输入电平流（0...1），供 HUD 波形消费。
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

    public func start() async throws {
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

        accumulator.reset()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // 2) 构建从硬件格式到目标格式的转换器（处理采样率 + 声道下混 + 量化）。
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecordingError.converterUnavailable
        }

        // 3) 安装 tap。回调在音频实时线程；这里同步把缓冲转换为目标格式并取出 Float 样本，
        //    再把 `[Float]`（Sendable）投递回 actor 累积——避免把非 Sendable 的
        //    AVAudioPCMBuffer 跨隔离域传递引发数据竞争。
        let targetFormat = self.targetFormat
        let levelContinuation = self.levelContinuation
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let samples = Self.convertToSamples(buffer, using: converter, to: targetFormat),
                  !samples.isEmpty else { return }
            // 在实时线程同步算出归一化电平后立即投递（continuation 为 Sendable，仅留最新值）。
            levelContinuation.yield(Self.normalizedLevel(samples))
            Task { await self.ingest(samples) }
        }

        // 4) 启动引擎。
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioRecordingError.engineStartFailed(error.localizedDescription)
        }
        recording = true
    }

    @discardableResult
    public func stop() async throws -> [Float] {
        guard recording else { throw AudioRecordingError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recording = false
        // 录音结束：把电平归零，让 HUD 波形平复（流本身保持有效以供下一次录音）。
        levelContinuation.yield(0)
        return accumulator.drain()
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
    private func ingest(_ samples: [Float]) {
        // 录音已停止后到达的迟到样本直接丢弃，避免污染下一次录音。
        guard recording else { return }
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
