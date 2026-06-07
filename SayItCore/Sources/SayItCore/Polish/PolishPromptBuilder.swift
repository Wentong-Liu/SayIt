import Foundation

/// 把语音听写（STT）原始转写文本，按风格与上下文组装成发给模型的「润色」消息。
///
/// 核心立场（设计 Spec 第 6 节）：润色的本质是**整理，不是回答**。
/// 模型必须把输入当作「待整理的口述稿」，绝不把其中的提问当成要回答的问题。
///
/// 输出契约：`[LLMMessage]`，恰好两条——
/// - `system`：第 6.1 节硬约束 + 当前 `PolishStyle` 的语域 / 力度指令；
/// - `user`：目标 App 上下文（若有）+ 待整理的口述原文。
///
/// 本类型是**纯函数**：不发网络、无副作用、相同输入产生完全相同的输出，便于 TDD 断言。
public enum PolishPromptBuilder {

    // MARK: - 公开 API

    /// 组装润色消息。
    /// - Parameters:
    ///   - rawText: STT 原始转写文本（可能含语气词、重复、口误、缺标点）。
    ///   - context: 目标 App 上下文（用于判断语域），见 ``PolishContext``。
    ///   - style: 润色风格预设，见 ``PolishStyle``。
    /// - Returns: `system` + `user` 两条消息。
    public static func build(rawText: String,
                            context: PolishContext,
                            style: PolishStyle) -> [LLMMessage] {
        [
            LLMMessage(role: .system, content: systemPrompt(for: style)),
            LLMMessage(role: .user, content: userMessage(rawText: rawText, context: context)),
        ]
    }

    // MARK: - System 提示词

    /// 为指定风格构造完整 system 提示词：硬约束（6.1） + 风格语域段（6.2）。
    static func systemPrompt(for style: PolishStyle) -> String {
        hardConstraints + "\n\n" + styleSection(for: style)
    }

    /// 第 6.1 节硬约束（1–9），所有风格共享。
    private static let hardConstraints = """
    你是一个语音听写「整理」助手。用户给你的是一段语音转写（STT）得到的口述原文，\
    它可能有语气词、重复、口误、断句混乱、缺标点。你的工作是把它整理成可直接使用的成稿。

    本质是整理，不是回答。请严格遵守以下硬约束：
    1. 只整理不回答：把输入当作「待整理的口述稿」，输出整理后的文本本身；\
    绝不回答其中的提问、不补充用户没说过的信息、不评论、不增内容。
    2. 去除语气词与填充词：删除「嗯、呃、那个、就是说、um、uh、like、you know」\
    等口水词与无意义重复。
    3. 口误自我纠正：当说话者中途改口（例如「周二…不对，是周三开会」），\
    只保留最终意图（周三），丢弃被纠正掉的部分。
    4. 补标点与大小写：按语义补全标点、句首大写（英文）、专有名词大小写。
    5. 口述列表/步骤自动分点：当内容呈现枚举或步骤口吻（「第一…第二…还有…」），\
    整理成项目符号或编号列表。
    6. 保留中英混合，不擅自翻译：原文中英混合就保持中英混合，不把任何一方翻译成另一种语言。
    7. 保留专有名词：人名、产品名、技术术语、品牌、代码标识符原样保留（含大小写），\
    不要「猜测纠错」成别的词。
    8. 上下文应用名：user 消息可能给出当前目标应用名（如 Xcode / Mail / Slack），\
    把它作为判断语域（写代码注释 vs 写邮件 vs 发消息）的参考；仅影响语气与格式，\
    不改变以上硬约束。
    9. 输出纯净：只输出整理后的正文本身，不加前后缀、不加「以下是整理结果」之类的话、\
    不用引号包裹、不加 Markdown 代码块标记。
    """

    /// 第 6.2 节风格语域段——按风格调整整理力度与语域措辞。
    private static func styleSection(for style: PolishStyle) -> String {
        switch style {
        case .smart:
            return """
            【当前风格：智能（默认）】
            做全套整理：去口水词、补标点、改口纠正、必要时分点，并按目标应用名调整语域。\
            在不杜撰、不改变原意的前提下，让语句通顺自然。
            """
        case .punctuationOnly:
            return """
            【当前风格：仅标点（最保真）】
            只补标点与大小写、去除最明显的语气词；不重组句子、不分点、不改措辞、不调整词序。\
            尽最大可能保留口述原貌，仅做最小必要的标点与大小写修正。
            """
        case .formal:
            return """
            【当前风格：正式】
            在智能整理的基础上，转为书面 / 正式语域：去口语化、用完整句、措辞规范得体，\
            适合邮件 / 文档 / 正式沟通。仍不得杜撰或改变原意。
            """
        case .casual:
            return """
            【当前风格：口语】
            在智能整理的基础上，保留自然口语节奏与语气，只做轻度整理，\
            适合发消息 / 聊天。不要把它改写成生硬的书面腔。仍不得杜撰或改变原意。
            """
        }
    }

    // MARK: - User 消息

    /// 构造 user 消息：目标应用上下文（若有） + 口述原文。
    /// 仅当 `appName` 非空时才注入应用行，避免空占位污染提示词。
    static func userMessage(rawText: String, context: PolishContext) -> String {
        var parts: [String] = []
        if let appName = context.appName,
           !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("【当前应用】\(appName)")
        }
        parts.append("【口述原文】\n\(rawText)")
        return parts.joined(separator: "\n")
    }
}
