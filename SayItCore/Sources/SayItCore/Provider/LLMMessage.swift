import Foundation

/// A single conversation message sent to the large model.
public struct LLMMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }
    public let role: Role
    public let content: String
    /// Attached images (base64 data URL); used only by vision Providers, ignored by others.
    public let imageDataURLs: [String]

    public init(role: Role, content: String, imageDataURLs: [String] = []) {
        self.role = role
        self.content = content
        self.imageDataURLs = imageDataURLs
    }
}
