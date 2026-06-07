import Foundation

/// 语音转写（Speech-To-Text）过程中可能抛出的错误。
public enum STTError: Error, Equatable, Sendable {
    /// 转写后端尚未就绪（例如模型未加载、权限未授予）。
    case notReady
    /// 输入音频为空，无可转写内容。
    case emptyAudio
    /// 不支持的采样率或音频格式。
    case unsupportedFormat
    /// 转写失败，附带可读原因。
    case transcriptionFailed(reason: String)
}

extension STTError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notReady:
            return "STTError.notReady"
        case .emptyAudio:
            return "STTError.emptyAudio"
        case .unsupportedFormat:
            return "STTError.unsupportedFormat"
        case let .transcriptionFailed(reason):
            return "STTError.transcriptionFailed(reason: \(reason))"
        }
    }
}
