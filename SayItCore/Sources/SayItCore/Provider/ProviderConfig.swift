import Foundation

/// Connection config for a large-model Provider (name/baseURL/model). The API Key is not stored here; it is passed in at call time.
public struct ProviderConfig: Equatable, Sendable {
    public let name: String
    public let baseURL: String   // e.g. "https://api.openai.com/v1"
    public let model: String
    public init(name: String, baseURL: String, model: String) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
    }
    public static func openAI(model: String) -> ProviderConfig {
        ProviderConfig(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: model)
    }
    public static func deepSeek(model: String) -> ProviderConfig {
        ProviderConfig(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: model)
    }
    public static func anthropic(model: String) -> ProviderConfig {
        ProviderConfig(name: "Anthropic", baseURL: "https://api.anthropic.com/v1", model: model)
    }
}
