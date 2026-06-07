import Foundation
import Security

/// A minimal Keychain read/write (generic password). Stores each Provider's API Key and the ChatGPT OAuthTokens.
///
/// Pushed down into the SayItCore package (originally in the ZhiYu app layer), so the App layer (CodexLoginService / ProviderFactory)
/// and in-package code can both reuse it, avoiding a circular reference between the App and the package. Cross-target calls require public visibility.
public enum KeychainStore {
    public static let service = "com.liuwentong.SayIt"
    /// The account name for the ChatGPT OAuth tokens.
    public static let chatGPTTokensAccount = "chatgpt.oauthTokens"

    /// A fixed API Key account constant (replacing ZhiYu's original data-driven ProviderKind.keychainAccount mapping).
    /// Sufficient for the foundation stage; to be extended later for multiple Providers.
    public enum Account {
        public static let openAIAPIKey = "openai.apiKey"
        public static let anthropicAPIKey = "anthropic.apiKey"
        public static let deepSeekAPIKey = "deepseek.apiKey"
    }

    /// Write a credential. Non-destructive write: first SecItemUpdate (returns true on success); if it does not exist, then SecItemAdd.
    /// Does not SecItemDelete first, to avoid losing the old value if the write fails. Returns whether it was actually written successfully.
    @discardableResult
    public static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 1) First try to update the existing item (only changing kSecValueData).
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        // 2) If it does not exist, add a new one (with full attributes).
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[SayIt][KeychainStore] SecItemAdd 写入失败 account=\(account) status=\(addStatus)")
            }
            return addStatus == errSecSuccess
        }
        // 3) Other errors: keep the old value, return failure.
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

    /// Write the ChatGPT OAuth tokens. Returns whether it was actually written successfully (encoding failure or Keychain write failure are both false).
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

    /// Clear the ChatGPT tokens. Returns whether it succeeded (already deleted or never existed are both treated as success).
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
