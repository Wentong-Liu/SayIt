import Foundation
import SayItCore

/// A streamlined Provider factory (removing ZhiYu's AppConfig / ProviderKind data-driven dependency).
/// At the foundation stage there is no complete settings UI, so it instead explicitly receives "transport + config" parameters to construct an LLMProvider.
/// Three transport branches:
///   - codexOAuth: uses CodexLoginService.validTokens() to get an OAuth token -> CodexResponsesProvider
///   - openAICompatible: gets the key from the Keychain -> OpenAICompatibleProvider (OpenAI / DeepSeek, etc.)
///   - anthropic: gets the key from the Keychain -> AnthropicProvider
@MainActor
enum ProviderFactory {
    /// Explicit transport description (replacing ZhiYu's ProviderKind.transport).
    enum Transport {
        /// ChatGPT(Codex) OAuth; model of the form "gpt-5-codex".
        case codexOAuth(model: String)
        /// OpenAI-compatible protocol (OpenAI / DeepSeek ...).
        /// - config: connection config (constructed with static factories like ProviderConfig.openAI/.deepSeek/.anthropic)
        /// - keychainAccount: the Keychain account storing this Provider's API Key (see KeychainStore.Account)
        /// - sendsImages: whether to send images along with the message (vision model true, text-only false)
        case openAICompatible(config: ProviderConfig, keychainAccount: String, sendsImages: Bool)
        /// Anthropic Messages protocol.
        case anthropic(config: ProviderConfig, keychainAccount: String)
    }

    static func make(_ transport: Transport) async throws -> any LLMProvider {
        switch transport {
        case let .codexOAuth(model):
            guard let tokens = await CodexLoginService.shared.validTokens() else {
                throw ProviderError.missingAPIKey
            }
            return CodexResponsesProvider(accessToken: tokens.accessToken,
                                          accountId: tokens.accountId, model: model)
        case let .openAICompatible(config, keychainAccount, sendsImages):
            let key = try keychainKey(account: keychainAccount)
            return OpenAICompatibleProvider(config: config, apiKey: key, sendsImages: sendsImages)
        case let .anthropic(config, keychainAccount):
            let key = try keychainKey(account: keychainAccount)
            return AnthropicProvider(config: config, apiKey: key)
        }
    }

    /// Gets and trims the API Key from the Keychain; throws missingAPIKey if empty.
    private static func keychainKey(account: String) throws -> String {
        let key = (KeychainStore.get(account: account) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ProviderError.missingAPIKey }
        return key
    }
}
