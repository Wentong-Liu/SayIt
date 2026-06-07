import Foundation

/// 各 LLM Provider 共享的采样/超时默认值（单一真相源）。
/// 改这里即同时影响所有 Provider，避免多处魔法数字漂移。
enum LLMDefaults {
    /// 采样温度。偏高以求回复多样、口语化。
    static let temperature: Double = 0.9
    /// 单次回复的最大 token 数（仅 Anthropic 协议需显式传，OpenAI 兼容协议用服务端默认）。
    static let maxTokens: Int = 1024
    /// 单次（非流式）请求超时（秒）。一次性返回，给足整体上限即可。
    static let requestTimeout: TimeInterval = 60
}
