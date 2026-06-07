import Foundation

/// Large-model Provider abstraction: given a set of messages, returns the assistant's raw reply text.
public protocol LLMProvider: Sendable {
    func complete(messages: [LLMMessage]) async throws -> String
}
