import AVFoundation
import Foundation

/// 录音过程中把一段段（已转换为目标格式的）PCM 缓冲累积成连续的 `[Float]`。
///
/// 这是 AudioRecorder 里可被单测覆盖的纯逻辑：不触碰硬件，只负责
/// “从 AVAudioPCMBuffer 取出 channel-0 的 Float32 样本并追加到内部数组”。
/// 真实采集（AVAudioEngine tap）只是不断喂 buffer 进来，本类不关心来源。
///
/// 非线程安全：调用方（AudioRecorder）需自行保证串行访问（实际由音频 tap 的
/// 单一 dispatch 顺序 + actor 隔离保证）。
public struct FloatSampleAccumulator {
    /// 已累积的样本。
    public private(set) var samples: [Float]

    public init() {
        self.samples = []
    }

    /// 已累积的样本数。
    public var count: Int { samples.count }

    /// 以目标采样率估算的已累积时长（秒）。
    public var durationSeconds: Double {
        Double(samples.count) / AudioFormat.sampleRate
    }

    /// 清空已累积的样本（复用同一累积器开始新一次录音前调用）。
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// 直接追加一段已就绪的 Float 样本（已是目标格式的 channel-0 样本）。
    public mutating func append(contentsOf newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    /// 把一个 PCM Float32 缓冲的 channel-0 样本追加进来。
    ///
    /// 期望 `buffer` 已是 Float32 格式（`commonFormat == .pcmFormatFloat32`）。
    /// 仅读取第 0 声道——上游应已转成单声道，多声道时只取首声道避免静默叠加错误。
    /// 若 buffer 不是 Float32、或没有 floatChannelData、或 frameLength 为 0，则忽略。
    /// 返回本次实际追加的样本数。
    @discardableResult
    public mutating func append(_ buffer: AVAudioPCMBuffer) -> Int {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let channel0 = channelData[0]
        samples.append(contentsOf: UnsafeBufferPointer(start: channel0, count: frameCount))
        return frameCount
    }

    /// 取出累积结果并清空内部缓冲（一次性消费，供 stop() 返回）。
    public mutating func drain() -> [Float] {
        let result = samples
        samples.removeAll(keepingCapacity: true)
        return result
    }
}
