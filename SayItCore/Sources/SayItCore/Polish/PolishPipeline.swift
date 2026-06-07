import Foundation

/// 一次润色的结果。
///
/// `text` 永远是「可直接注入」的最终文本——成功时是模型整理稿，失败/跳过时是原始口述（trim 后）。
/// 设计立场：**绝不丢用户的话**，任何异常都回退到原文，并通过 `polished` / `usedFallback` 标明发生了什么。
public struct PolishOutcome: Equatable, Sendable {
    /// 最终可用文本（已 trim）。成功为模型输出，回退为原始 rawText。
    public let text: String
    /// 是否真正经过模型润色（成功路径为 true）。
    public let polished: Bool
    /// 是否走了回退（原文）路径：抛错 / 超时 / 空响应 / 关闭润色 / 空输入皆为 true。
    public let usedFallback: Bool

    public init(text: String, polished: Bool, usedFallback: Bool) {
        self.text = text
        self.polished = polished
        self.usedFallback = usedFallback
    }
}

/// 把 STT 原始转写文本润色为成稿的管线。
///
/// 流程：用已有 ``PolishPromptBuilder`` 组装 `[LLMMessage]` → 调用调用方注入的
/// ``LLMProvider/complete(messages:)`` → 返回整理后文本（trim）。
///
/// 依赖倒置：本类型**不构造任何具体 Provider**，由调用方注入 ``LLMProvider``，
/// 与 App 层的 ProviderFactory 解耦，便于在 Core 内用 Fake 做 TDD。
///
/// 健壮性约定（绝不丢用户的话）：
/// - provider 抛错 / 超时 → 回退原文，`polished=false`、`usedFallback=true`；
/// - provider 返回空 / 仅空白 → 回退原文（同上）；
/// - `polishEnabled == false` → 直接返回原文，不调用 provider；
/// - 输入为空 / 仅空白 → 直接返回 trim 后的输入，不调用 provider。
public struct PolishPipeline: Sendable {

    public init() {}

    /// 润色一段原始口述文本。
    /// - Parameters:
    ///   - rawText: STT 原始转写文本。
    ///   - context: 目标 App 上下文（用于判断语域），见 ``PolishContext``。
    ///   - style: 润色风格，见 ``PolishStyle``。
    ///   - provider: 由调用方注入的大模型 Provider，见 ``LLMProvider``。
    ///   - polishEnabled: 是否启用润色；为 `false` 时直接返回原文（默认 `true`）。
    /// - Returns: 见 ``PolishOutcome``——`text` 永远是可直接使用的文本。
    public func polish(_ rawText: String,
                       context: PolishContext,
                       style: PolishStyle,
                       provider: LLMProvider,
                       polishEnabled: Bool = true) async -> PolishOutcome {
        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空输入：没东西可润色，直接走原文（trim 后）。
        guard !trimmedRaw.isEmpty else {
            return PolishOutcome(text: trimmedRaw, polished: false, usedFallback: true)
        }

        // 关闭润色：原样返回原文，不触网。
        guard polishEnabled else {
            return PolishOutcome(text: trimmedRaw, polished: false, usedFallback: true)
        }

        let messages = PolishPromptBuilder.build(rawText: rawText, context: context, style: style)

        do {
            let raw = try await provider.complete(messages: messages)
            let polishedText = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            // 空响应：模型没给出可用文本 → 回退原文，绝不返回空。
            guard !polishedText.isEmpty else {
                return PolishOutcome(text: trimmedRaw, polished: false, usedFallback: true)
            }

            return PolishOutcome(text: polishedText, polished: true, usedFallback: false)
        } catch {
            // 抛错 / 超时（CancellationError 等）→ 回退原文。
            return PolishOutcome(text: trimmedRaw, polished: false, usedFallback: true)
        }
    }
}
