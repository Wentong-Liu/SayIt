import Foundation
import Security

/// 极简 Keychain 读写（generic password）。存各 Provider 的 API Key 与 ChatGPT OAuthTokens。
///
/// 下沉到 SayItCore 包内（原在 ZhiYu app 层），因此 App 层（CodexLoginService / ProviderFactory）
/// 与包内代码都能复用，避免 App↔包之间出现循环引用。跨 target 调用需 public 可见性。
public enum KeychainStore {
    public static let service = "com.liuwentong.SayIt"
    /// ChatGPT OAuth tokens 的 account 名。
    public static let chatGPTTokensAccount = "chatgpt.oauthTokens"

    /// 固定的 API Key account 常量（取代原 ZhiYu 的 ProviderKind.keychainAccount 数据驱动映射）。
    /// 地基阶段够用；后续多 Provider 时再扩展。
    public enum Account {
        public static let openAIAPIKey = "openai.apiKey"
        public static let anthropicAPIKey = "anthropic.apiKey"
        public static let deepSeekAPIKey = "deepseek.apiKey"
    }

    /// 写入凭证。非破坏写：先 SecItemUpdate（成功即返回 true）；不存在时再 SecItemAdd。
    /// 不先 SecItemDelete，避免写入失败时丢掉旧值。返回是否真正写入成功。
    @discardableResult
    public static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 1) 先尝试更新现有项（仅改 kSecValueData）。
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        // 2) 不存在则新增（带完整属性）。
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[SayIt][KeychainStore] SecItemAdd 写入失败 account=\(account) status=\(addStatus)")
            }
            return addStatus == errSecSuccess
        }
        // 3) 其它错误：保留旧值、返回失败。
        NSLog("[SayIt][KeychainStore] SecItemUpdate 写入失败 account=\(account) status=\(updateStatus)")
        return false
    }

    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// 写入 ChatGPT OAuth tokens。返回是否真正写入成功（编码失败或 Keychain 写入失败均为 false）。
    @discardableResult
    public static func saveChatGPTTokens(_ tokens: OAuthTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else {
            NSLog("[SayIt][KeychainStore] saveChatGPTTokens 编码失败")
            return false
        }
        return set(String(decoding: data, as: UTF8.self), account: chatGPTTokensAccount)
    }

    public static func loadChatGPTTokens() -> OAuthTokens? {
        guard let s = get(account: chatGPTTokensAccount), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    /// 清除 ChatGPT tokens。返回是否成功（已删除或本就不存在均视为成功）。
    @discardableResult
    public static func clearChatGPTTokens() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: chatGPTTokensAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        let ok = (status == errSecSuccess || status == errSecItemNotFound)
        if !ok {
            NSLog("[SayIt][KeychainStore] clearChatGPTTokens 删除失败 status=\(status)")
        }
        return ok
    }
}
