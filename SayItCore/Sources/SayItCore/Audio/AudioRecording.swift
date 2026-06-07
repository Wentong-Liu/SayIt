import Foundation

/// 录音过程中可能发生的错误。
public enum AudioRecordingError: Error, Sendable {
    /// 未获得麦克风权限（被拒绝/受限/用户未授权）。
    case microphonePermissionDenied
    /// 已经在录音中，重复调用 `start()`。
    case alreadyRecording
    /// 当前没有在录音，却调用了 `stop()`。
    case notRecording
    /// 无法为输入流构建目标格式的转换器（采样率/声道转换失败）。
    case converterUnavailable
    /// AVAudioEngine 启动失败，附带底层错误描述。
    case engineStartFailed(String)
}

extension AudioRecordingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .microphonePermissionDenied:
            return "AudioRecordingError.microphonePermissionDenied"
        case .alreadyRecording:
            return "AudioRecordingError.alreadyRecording"
        case .notRecording:
            return "AudioRecordingError.notRecording"
        case .converterUnavailable:
            return "AudioRecordingError.converterUnavailable"
        case let .engineStartFailed(message):
            return "AudioRecordingError.engineStartFailed(\(message))"
        }
    }
}

/// 麦克风录音抽象：开始采集、停止并取回累积的 Float32 单声道 16kHz 样本。
///
/// 设计为协议，便于上层（听写流水线）依赖抽象、单测时替换为假实现，
/// 也方便后续替换底层采集方案而不影响调用方。
///
/// 约定：`stop()` 返回的样本即为 `AudioFormat`（16kHz / 单声道 / Float32）。
public protocol AudioRecording: Sendable {
    /// 开始录音。若未授权会先尝试请求权限；仍未授权则抛 `.microphonePermissionDenied`。
    /// 已在录音时抛 `.alreadyRecording`。
    func start() async throws

    /// 停止录音并返回本次累积的全部样本（16kHz / 单声道 / Float32）。
    /// 未在录音时抛 `.notRecording`。
    @discardableResult
    func stop() async throws -> [Float]

    /// 是否正在录音。
    var isRecording: Bool { get async }
}
