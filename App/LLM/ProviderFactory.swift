import Foundation
import SayItCore

/// 精简版 Provider 工厂（去掉 ZhiYu 的 AppConfig / ProviderKind 数据驱动依赖）。
/// 地基阶段没有完整设置 UI，改为显式接收「传输方式 + 配置」参数来构造一个 LLMProvider。
/// 三条传输分支：
///   - codexOAuth：用 CodexLoginService.validTokens() 取 OAuth token → CodexResponsesProvider
///   - openAICompatible：从 Keychain 取 key → OpenAICompatibleProvider（OpenAI / DeepSeek 等）
///   - anthropic：从 Keychain 取 key → AnthropicProvider
@MainActor
enum ProviderFactory {
    /// 显式传输描述（取代 ZhiYu 的 ProviderKind.transport）。
    enum Transport {
        /// ChatGPT(Codex) OAuth；model 形如 "gpt-5-codex"。
        case codexOAuth(model: String)
        /// OpenAI 兼容协议（OpenAI / DeepSeek …）。
        /// - config: 连接配置（用 ProviderConfig.openAI/.deepSeek/.anthropic 等静态工厂构造）
        /// - keychainAccount: 存放该 Provider API Key 的 Keychain account（见 KeychainStore.Account）
        /// - sendsImages: 是否把图片随消息发出（视觉模型 true，纯文本 false）
        case openAICompatible(config: ProviderConfig, keychainAccount: String, sendsImages: Bool)
        /// Anthropic Messages 协议。
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

    /// 从 Keychain 取并修整 API Key；为空抛 missingAPIKey。
    private static func keychainKey(account: String) throws -> String {
        let key = (KeychainStore.get(account: account) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ProviderError.missingAPIKey }
        return key
    }
}
