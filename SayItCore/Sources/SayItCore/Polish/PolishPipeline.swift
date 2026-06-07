import Foundation

/// 一次润色的「裁决」：区分润色成功、按配置跳过、以及失败回退（携可观测原因）。
///
/// 设计目的：把过去单一的 `usedFallback` 布尔展开成可区分的语义，便于调用方与日志
/// 分辨「跳过（用户主动关闭/无内容）」与「失败回退（出了问题）」，从而可选地给出反馈。
/// 无论哪种分支，``PolishOutcome/text`` 始终是可直接注入的文本——**绝不丢用户的话**。
public enum PolishResolution: Equatable, Sendable {
    /// 真正经过模型润色并采用了模型输出。
    case polished
    /// 按配置/输入跳过润色，原样使用原文（未触网）。
    case skipped(SkipReason)
    /// 调用了模型但失败，回退原文。携带可读的失败原因（便于日志/反馈）。
    case failedFallback(reason: String)

    /// 跳过润色的具体原因（均不触网）。
    public enum SkipReason: Equatable, Sendable {
        /// 调用方关闭了润色（`polishEnabled == false`）。
        case disabled
        /// 输入为空 / 仅空白，没东西可润色。
        case emptyInput
    }
}

/// 一次润色的结果。
///
/// `text` 永远是「可直接注入」的最终文本——成功时是模型整理稿，失败/跳过时是原始口述（trim 后）。
/// 设计立场：**绝不丢用户的话**，任何异常都回退到原文，并通过 ``resolution`` 标明发生了什么。
///
/// 兼容性：保留 `polished` / `usedFallback` 两个派生布尔（由 ``resolution`` 推导），
/// 既有调用方与单测无需改动；新代码应优先读 ``resolution`` 以区分跳过与失败回退。
public struct PolishOutcome: Equatable, Sendable {
    /// 最终可用文本（已 trim）。成功为模型输出，回退为原始 rawText。
    public let text: String
    /// 本次润色的裁决（成功 / 跳过 / 失败回退）。
    public let resolution: PolishResolution

    /// 是否真正经过模型润色（仅 `.polished` 为 true）。
    public var polished: Bool { resolution == .polished }

    /// 是否走了回退（原文）路径：跳过或失败回退皆为 true，仅 `.polished` 为 false。
    public var usedFallback: Bool { resolution != .polished }

    /// 失败回退时的可读原因；其余分支为 nil（便于调用方/日志观测）。
    public var failureReason: String? {
        if case let .failedFallback(reason) = resolution { return reason }
        return nil
    }

    public init(text: String, resolution: PolishResolution) {
        self.text = text
        self.resolution = resolution
    }

    /// 兼容旧调用点的便捷构造：由 `polished` / `usedFallback` 反推 ``resolution``。
    /// - `polished == true` → `.polished`
    /// - 否则 → `.skipped(.disabled)`（无具体原因时的通用回退归类）。
    @available(*, deprecated, message: "改用 init(text:resolution:) 以携带明确的裁决/原因")
    public init(text: String, polished: Bool, usedFallback: Bool) {
        self.text = text
        self.resolution = polished ? .polished : .skipped(.disabled)
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

    /// 可选的失败日志回调：仅在「失败回退」时调用，携可读原因。
    /// 默认 nil（不记录）；App 层可注入打印/上报以便排查。`@Sendable` 以满足并发安全。
    private let logFailure: (@Sendable (String) -> Void)?

    /// - Parameter logFailure: 失败回退时的日志回调（可选）。
    public init(logFailure: (@Sendable (String) -> Void)? = nil) {
        self.logFailure = logFailure
    }

    /// 润色一段原始口述文本。
    /// - Parameters:
    ///   - rawText: STT 原始转写文本。
    ///   - context: 目标 App 上下文（用于判断语域），见 ``PolishContext``。
    ///   - style: 润色风格，见 ``PolishStyle``。
    ///   - provider: 由调用方注入的大模型 Provider，见 ``LLMProvider``。
    ///   - polishEnabled: 是否启用润色；为 `false` 时直接返回原文（默认 `true`）。
    /// - Returns: 见 ``PolishOutcome``——`text` 永远是可直接使用的文本，``PolishOutcome/resolution`` 标明分支。
    public func polish(_ rawText: String,
                       context: PolishContext,
                       style: PolishStyle,
                       provider: LLMProvider,
                       polishEnabled: Bool = true) async -> PolishOutcome {
        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空输入：没东西可润色，直接走原文（trim 后）。
        guard !trimmedRaw.isEmpty else {
            return PolishOutcome(text: trimmedRaw, resolution: .skipped(.emptyInput))
        }

        // 关闭润色：原样返回原文，不触网。
        guard polishEnabled else {
            return PolishOutcome(text: trimmedRaw, resolution: .skipped(.disabled))
        }

        let messages = PolishPromptBuilder.build(rawText: rawText, context: context, style: style)

        do {
            let raw = try await provider.complete(messages: messages)
            let polishedText = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            // 空响应：模型没给出可用文本 → 回退原文，绝不返回空。
            guard !polishedText.isEmpty else {
                return fallback(trimmedRaw, reason: "模型返回空响应")
            }

            return PolishOutcome(text: polishedText, resolution: .polished)
        } catch {
            // 抛错 / 超时（CancellationError 等）→ 回退原文。
            return fallback(trimmedRaw, reason: Self.describe(error))
        }
    }

    /// 失败回退：记录原因（若注入了 logger）并返回携原文的 `.failedFallback` 结果。
    private func fallback(_ rawText: String, reason: String) -> PolishOutcome {
        logFailure?(reason)
        return PolishOutcome(text: rawText, resolution: .failedFallback(reason: reason))
    }

    /// 把任意错误压成简短可读串，供日志/反馈使用。
    private static func describe(_ error: Error) -> String {
        if error is CancellationError { return "润色超时或被取消" }
        if let providerError = error as? ProviderError { return String(describing: providerError) }
        return error.localizedDescription
    }
}
