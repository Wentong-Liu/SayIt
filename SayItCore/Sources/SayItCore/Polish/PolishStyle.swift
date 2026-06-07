import Foundation

/// 润色风格预设（见设计 Spec 第 6.2 节）。
///
/// 风格只影响 system 提示词中「语域 / 整理力度」那一段的措辞，
/// 不改变第 6.1 节的硬约束（只整理不回答、去语气词、保真等）。
public enum PolishStyle: String, CaseIterable, Codable, Sendable {
    /// 智能（默认）：全套整理——去口水词、补标点、改口纠正、必要时分点、按 App 名调语域。
    case smart
    /// 仅标点：只补标点与大小写、去最明显口水词；不重组句子、不分点、不改措辞（最保真）。
    case punctuationOnly
    /// 正式：在「智能」基础上转为书面 / 正式语域（去口语化、完整句）。
    case formal
    /// 口语：在「智能」基础上保留自然口语节奏（适合发消息 / 聊天），轻整理。
    case casual
}
