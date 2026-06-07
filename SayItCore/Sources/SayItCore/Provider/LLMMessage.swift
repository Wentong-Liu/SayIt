import Foundation

/// 发给大模型的一条对话消息。
public struct LLMMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }
    public let role: Role
    public let content: String
    /// 附带图像（base64 data URL）；仅视觉 Provider 使用，其它忽略。
    public let imageDataURLs: [String]

    public init(role: Role, content: String, imageDataURLs: [String] = []) {
        self.role = role
        self.content = content
        self.imageDataURLs = imageDataURLs
    }
}
