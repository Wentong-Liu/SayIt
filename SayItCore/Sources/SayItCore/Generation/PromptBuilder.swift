import Foundation

/// 把语音听写（STT）原始转写文本组装成发给模型的「润色」消息。
///
/// 与 ZhiYu 微信版的 PromptBuilder 不同：这里是单段听写润色，不做多候选 / JSON 数组 /
/// 多气泡拆分 / 表情 / 草稿续写 / 图片。仅沿用其「双消息（system + user）组装、像真人不客服」
/// 的骨架与措辞灵感。
/// 输入 = STT 原始转写文本；输出契约 = 单段润色后的纯文本（无编号、无解释、无引号包裹）。
public enum PromptBuilder {
    /// 默认润色 system prompt（单一真相源）。强调：保真去口水、不杜撰、保留原意与语言。
    public static let defaultSystemPrompt = """
    你是一个语音听写润色助手。用户会给你一段语音转写（STT）得到的原始文本，
    它可能有口水词、重复、语气词、口误、断句混乱、缺标点。请把它润色成通顺、
    自然、可直接使用的书面文本。

    要求：
    - 严格保留原意，绝不杜撰、扩写或补充用户没说过的信息。
    - 去掉口水词与无意义重复（嗯、啊、那个、就是、然后然后…），修正明显口误。
    - 补全标点、理顺断句，让语句通顺；保留原本的口语自然度，不要写成生硬的公文腔。
    - 保持原文使用的语言（中文输入就输出中文，英文就输出英文）。
    - 不要加任何前后缀、解释、标题、引号或 Markdown 标记。
    - 只输出润色后的正文本身，作为单段文本返回。
    """

    /// 组装润色消息：system（润色指令）+ user（待润色的转写文本）。
    /// - Parameters:
    ///   - transcript: STT 原始转写文本。
    ///   - systemPrompt: 可覆盖的润色指令；默认用 `defaultSystemPrompt`。
    public static func build(transcript: String,
                             systemPrompt: String = defaultSystemPrompt) -> [LLMMessage] {
        [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user, content: transcript),
        ]
    }
}
