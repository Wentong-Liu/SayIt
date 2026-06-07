import Foundation

/// Whisper 所需的目标音频格式：16kHz、单声道、32 位浮点（PCM Float32）。
///
/// AudioRecorder 抓取的麦克风原始流（采样率/声道随硬件而定）会被转换到此格式后，
/// 累积成 `[Float]` 供后续转写使用。集中为单一真相源，方便测试与复用。
public enum AudioFormat {
    /// 目标采样率（Hz）。Whisper 模型固定以 16kHz 训练。
    public static let sampleRate: Double = 16_000

    /// 目标声道数（单声道）。
    public static let channelCount: UInt32 = 1

    /// 每个样本的字节数（Float32 = 4 字节）。
    public static let bytesPerSample = 4
}
