import Foundation

/// 各 Provider 共享的 HTTP 字面量（header 名/值、路径后缀）单一真相源。
/// 收敛散落在各 Provider 里的内联字符串，避免大小写/拼写漂移。
enum HTTPConstants {
    // MARK: - Header 名（按 HTTP 规范的规范化大小写；header 名本身大小写不敏感）
    static let contentTypeHeader = "Content-Type"
    static let acceptHeader = "Accept"
    static let authorizationHeader = "Authorization"

    // MARK: - Header 值
    static let applicationJSON = "application/json"

    // MARK: - 路径后缀
    /// OpenAI 兼容协议的补全端点后缀（拼在 baseURL 之后）。
    static let chatCompletionsPath = "/chat/completions"
    /// Anthropic Messages API 的端点后缀（拼在 baseURL 之后）。
    static let messagesPath = "/messages"
}

extension URLRequest {
    /// 写入 `Authorization: Bearer <token>`。各 Provider 统一走这里，避免重复拼前缀。
    mutating func setBearerAuthorization(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: HTTPConstants.authorizationHeader)
    }
}
