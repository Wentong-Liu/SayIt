import Foundation

/// 语音转写后端的抽象接口。
///
/// 具体实现可以是本地模型（如 WhisperKit）或云端服务；本协议保持后端无关，
/// 上层只依赖此接口，便于替换实现与在测试中注入 ``FakeTranscriber``。
public protocol Transcriber: Sendable {
    /// 将 PCM 浮点音频转写为文本。
    ///
    /// - Parameters:
    ///   - audio: 单声道 PCM 样本，取值范围约 `[-1, 1]`。
    ///   - sampleRate: 音频采样率（Hz），例如 `16_000`。
    ///   - language: 可选的 BCP-47 / ISO 语言代码（如 `"en"`、`"zh"`）；
    ///     传 `nil` 表示让后端自动检测。
    /// - Returns: 转写结果 ``TranscriptionResult``。
    /// - Throws: 转写失败时抛出 ``STTError``。
    func transcribe(_ audio: [Float], sampleRate: Double, language: String?) async throws -> TranscriptionResult
}
