import Foundation

/// 大模型 Provider 抽象：给定一组消息，返回助手的原始回复文本。
public protocol LLMProvider: Sendable {
    func complete(messages: [LLMMessage]) async throws -> String
}
