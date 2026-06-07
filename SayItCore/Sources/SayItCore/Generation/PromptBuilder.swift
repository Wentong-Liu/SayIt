import Foundation

/// Assembles the raw speech-to-text (STT) transcription text into a "polish" message sent to the model.
///
/// Different from the PromptBuilder of ZhiYu's WeChat version: this is single-segment dictation polish, with no multi-candidate / JSON array /
/// multi-bubble splitting / emoji / draft continuation / images. It only reuses its "two-message (system + user) assembly, human-like not customer-service"
/// skeleton and wording inspiration.
/// Input = raw STT transcription text; output contract = a single segment of polished plain text (no numbering, no explanation, no quote wrapping).
public enum PromptBuilder {
    /// The default polish system prompt (single source of truth). Emphasizes: stay faithful and remove filler words, do not fabricate, preserve the original meaning and language.
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

    /// Assembles the polish message: system (polish instructions) + user (the transcription text to polish).
    /// - Parameters:
    ///   - transcript: the raw STT transcription text.
    ///   - systemPrompt: overridable polish instructions; defaults to `defaultSystemPrompt`.
    public static func build(transcript: String,
                             systemPrompt: String = defaultSystemPrompt) -> [LLMMessage] {
        [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user, content: transcript),
        ]
    }
}
