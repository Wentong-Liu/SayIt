import Foundation

/// 听写触发用的修饰键。双击/按住该键触发录音。
///
/// `rawValue` 为落盘字符串：**改了会读不到旧配置**，须与历史保持一致。
public enum TriggerKey: String, CaseIterable, Identifiable, Sendable {
    case rightCommand
    case leftCommand
    case rightOption
    case leftOption
    case rightControl
    case fn

    public var id: String { rawValue }

    /// 默认触发键：右⌘（不挡左手常用快捷键）。
    public static let `default`: TriggerKey = .rightCommand

    /// 设置面板展示名。
    public var displayName: String {
        switch self {
        case .rightCommand: return "右 ⌘"
        case .leftCommand:  return "左 ⌘"
        case .rightOption:  return "右 ⌥"
        case .leftOption:   return "左 ⌥"
        case .rightControl: return "右 ⌃"
        case .fn:           return "fn"
        }
    }
}

/// 触发交互方式：按住说话 vs 单击切换。
///
/// `rawValue` 为落盘字符串，不可随意更名。
public enum InteractionMode: String, CaseIterable, Identifiable, Sendable {
    /// 按住触发键录音，松开结束（push-to-talk）。
    case hold
    /// 单击开始录音，再次单击结束（toggle）。
    case toggle

    public var id: String { rawValue }

    /// 默认交互方式：按住说话。
    public static let `default`: InteractionMode = .hold

    public var displayName: String {
        switch self {
        case .hold:   return "按住说话"
        case .toggle: return "单击切换"
        }
    }
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

/// 润色风格：决定送给 LLM 的润色指令倾向。
///
/// `rawValue` 为落盘字符串，不可随意更名。
public enum PolishStyle: String, CaseIterable, Identifiable, Sendable {
    /// 智能润色：去口水、补标点、理顺断句，保留口语自然度。
    case smart
    /// 仅补标点：尽量保留原文措辞，只补全标点与断句。
    case punctuationOnly
    /// 正式书面：偏书面、严谨的措辞。
    case formal
    /// 轻松随意：偏口语、轻松的措辞。
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
