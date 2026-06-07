import Foundation

/// 用于测试与上层模块开发的 ``Transcriber`` 假实现。
///
/// 可注入一个预设的 ``TranscriptionResult`` 或一个 ``STTError``：
/// 注入结果时每次调用都返回该结果；注入错误时每次调用都抛出该错误。
/// 实现为 `actor`，因而是 `Sendable`，并在内部记录每次调用的入参，
/// 供测试断言参数传递是否正确。
public actor FakeTranscriber: Transcriber {
    /// 一次 ``transcribe(_:sampleRate:language:)`` 调用的入参快照。
    public struct Call: Equatable, Sendable {
        public let audio: [Float]
        public let sampleRate: Double
        public let language: String?

        public init(audio: [Float], sampleRate: Double, language: String?) {
            self.audio = audio
            self.sampleRate = sampleRate
            self.language = language
        }
    }

    private enum Outcome: Sendable {
        case success(TranscriptionResult)
        case failure(STTError)
    }

    private let outcome: Outcome

    /// 按调用先后顺序记录的全部调用入参。
    public private(set) var calls: [Call] = []

    /// 注入一个完整的预设结果。
    public init(result: TranscriptionResult) {
        self.outcome = .success(result)
    }

    /// 便捷初始化：仅指定返回文本，其余字段使用默认值。
    public init(text: String) {
        self.outcome = .success(TranscriptionResult(text: text))
    }

    /// 注入一个错误，使每次调用都抛出它。
    public init(error: STTError) {
        self.outcome = .failure(error)
    }

    public func transcribe(_ audio: [Float], sampleRate: Double, language: String?) async throws -> TranscriptionResult {
        calls.append(Call(audio: audio, sampleRate: sampleRate, language: language))
        switch outcome {
        case let .success(result):
            return result
        case let .failure(error):
            throw error
        }
    }
}
