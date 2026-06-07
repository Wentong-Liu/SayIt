import Foundation

// NOTE: `TriggerKey` 的单一真相源在 ``Hotkey/TriggerKey.swift``（含 keyCode /
// modifierFlag / label 等热键运行期所需成员，以及 leftControl、fnGlobe 完整用例）。
// 此处不再重复声明，仅保留其余配置枚举。配置面板展示名见该类型的 `displayName`。

/// 触发交互方式：单击切换 / 按住说话。
///
/// `rawValue` 为落盘字符串，不可随意更名。
public enum InteractionMode: String, CaseIterable, Identifiable, Sendable {
    /// 孤立单击修饰键开始录音，再次单击结束（默认，类似 Typeless / 闪电说）。
    case singleTap
    /// 按住触发键录音，松开结束（push-to-talk）。
    case hold

    public var id: String { rawValue }

    /// 默认交互方式：单击切换（孤立轻点）。
    public static let `default`: InteractionMode = .singleTap

    /// 自定义 `RawRepresentable` 初始化：已废弃的旧值（如曾落盘的 `"toggle"` 双击切换）
    /// 安全回落到默认（单击切换），不返回 `nil`，避免读旧配置时报错或丢交互方式。
    public init(rawValue: String) {
        switch rawValue {
        case "singleTap": self = .singleTap
        case "hold":      self = .hold
        default:          self = .default
        }
    }

    public var displayName: String {
        switch self {
        case .singleTap: return "单击切换"
        case .hold:      return "按住说话"
        }
    }
}

/// 界面显示语言。仅支持英文与简体中文两项（T24 需求）。
///
/// `rawValue` 为落盘的 BCP-47 标识，同时用作 `Locale(identifier:)`，**不可随意更名**。
/// 展示名固定为该语言的自称（`English` / `简体中文`），不参与本地化——这是语言选择器的惯例，
/// 让用户无论当前界面语言为何都能认出目标语言。
public enum UILanguage: String, CaseIterable, Identifiable, Sendable {
    /// 英文。
    case english = "en"
    /// 简体中文。
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    /// 默认界面语言：跟随系统首选语言映射到二者之一（中文系→简体中文，其余→英文）。
    public static let `default`: UILanguage = .english

    /// 按系统首选语言映射到受支持的两项之一：首选语言以 `zh` 开头视为简体中文，否则英文。
    public static var systemDefault: UILanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// 展示名：该语言的自称（不本地化）。
    public var displayName: String {
        switch self {
        case .english:           return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// 对应的 `Locale`，用于 `environment(\.locale:)` 即时重定位 SwiftUI 文案。
    public var locale: Locale { Locale(identifier: rawValue) }
}

/// 语音转文字（STT）的运行位置：本地模型 vs 云端 API。
///
/// `rawValue` 为落盘字符串，不可随意更名。
public enum STTMode: String, CaseIterable, Identifiable, Sendable {
    /// 本地模型（如 WhisperKit），离线、隐私优先。
    case local
    /// 云端转写 API（如 OpenAI transcribe），需联网与凭证。
    case cloud

    public var id: String { rawValue }

    /// 默认 STT：本地，隐私优先。
    public static let `default`: STTMode = .local

    public var displayName: String {
        switch self {
        case .local: return "本地模型"
        case .cloud: return "云端 API"
        }
    }
}

/// 润色风格：决定送给 LLM 的润色指令倾向（见设计 Spec 第 6.2 节）。
///
/// 风格只影响 system 提示词中「语域 / 整理力度」那一段的措辞，
/// 不改变第 6.1 节的硬约束（只整理不回答、去语气词、保真等）。
///
/// `rawValue` 为落盘字符串，不可随意更名。
public enum PolishStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 智能（默认）：全套整理——去口水词、补标点、改口纠正、必要时分点、按 App 名调语域，保留口语自然度。
    case smart
    /// 仅标点：只补标点与大小写、去最明显口水词；不重组句子、不分点、不改措辞（最保真）。
    case punctuationOnly
    /// 正式书面：在「智能」基础上转为书面 / 正式语域（去口语化、完整句）。
    case formal
    /// 轻松随意：在「智能」基础上保留自然口语节奏（适合发消息 / 聊天），轻整理。
    case casual

    public var id: String { rawValue }

    /// 默认润色风格：智能润色。
    public static let `default`: PolishStyle = .smart

    public var displayName: String {
        switch self {
        case .smart:           return "智能润色"
        case .punctuationOnly: return "仅补标点"
        case .formal:          return "正式书面"
        case .casual:          return "轻松随意"
        }
    }
}

/// 润色所用大模型 Provider 种类。
///
/// 仅覆盖 sayit 当前支持的 Provider；`rawValue` 为落盘字符串（同时用作展示名），
/// **改了会读不到旧配置**，须与历史保持一致。模型清单与默认模型集中于此，作单一真相源。
public enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case anthropic = "Anthropic"
    case chatGPT = "ChatGPT 登录"

    public var id: String { rawValue }

    /// 默认 Provider：OpenAI。
    public static let `default`: ProviderKind = .openAI

    /// 展示名（与 `rawValue` 同源）。
    public var displayName: String { rawValue }

    /// 该 Provider 可选模型：(id 发给 API, label 展示)。润色文本任务，默认偏向轻量/便宜模型。
    public var modelOptions: [(id: String, label: String)] {
        switch self {
        case .openAI:
            return [("gpt-4o-mini", "GPT-4o mini"), ("gpt-4o", "GPT-4o"),
                    ("gpt-4.1-mini", "GPT-4.1 mini")]
        case .deepSeek:
            return [("deepseek-chat", "DeepSeek Chat")]
        case .anthropic:
            return [("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
                    ("claude-sonnet-4-6", "Claude Sonnet 4.6")]
        case .chatGPT:
            return [("gpt-4o-mini", "GPT-4o mini"), ("gpt-4o", "GPT-4o")]
        }
    }

    /// 该 Provider 的默认模型（取 `modelOptions` 首项）。
    public var defaultModel: String { modelOptions.first?.id ?? "" }
}
