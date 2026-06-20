import Foundation

// NOTE: The single source of truth for `TriggerKey` is in ``Hotkey/TriggerKey.swift`` (containing keyCode /
// modifierFlag / label and other hotkey-runtime members, plus the complete leftControl, fnGlobe cases).
// It is no longer redeclared here; only the remaining config enums are kept. For the settings-panel display name, see that type's `displayName`.

/// Trigger interaction style: tap to toggle / hold to talk.
///
/// `rawValue` is the persisted string and must not be renamed arbitrarily.
public enum InteractionMode: String, CaseIterable, Identifiable, Sendable {
    /// An isolated tap of the modifier key starts recording, another tap ends it (default, similar to Typeless / Shandianshuo).
    case singleTap
    /// Hold the trigger key to record, release to end (push-to-talk).
    case hold

    public var id: String { rawValue }

    /// Default interaction style: tap to toggle (isolated tap).
    public static let `default`: InteractionMode = .singleTap

    /// Custom `RawRepresentable` initialization: a deprecated old value (e.g. the previously persisted `"toggle"` double-tap toggle)
    /// safely falls back to the default (tap to toggle) without returning `nil`, to avoid errors or losing the interaction style when reading old config.
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

    /// The localization key for the settings-panel Picker display (stored in the App-side `Localizable.xcstrings`).
    /// The view renders with `Text(LocalizedStringKey(localizationKey))`, switching language instantly with `uiLocale` (the environment locale).
    public var localizationKey: String {
        switch self {
        case .singleTap: return "interaction.singleTap"
        case .hold:      return "interaction.hold"
        }
    }
}

/// The UI display language. Supports only English and Simplified Chinese (T24 requirement).
///
/// `rawValue` is the persisted BCP-47 identifier, also used as `Locale(identifier:)`, and **must not be renamed arbitrarily**.
/// The display name is fixed to that language's endonym (`English` / Simplified Chinese), not localized -- this is the convention for a language picker,
/// letting users recognize the target language regardless of the current UI language.
public enum UILanguage: String, CaseIterable, Identifiable, Sendable {
    /// English.
    case english = "en"
    /// Simplified Chinese.
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    /// Maps the system preferred language to one of the two supported options: a preferred language starting with `zh` is treated as Simplified Chinese, otherwise English.
    /// This is the default used by ``AppConfig/uiLanguage`` when the key is unset, so first launch follows the system language.
    public static var systemDefault: UILanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// Display name: that language's endonym (not localized).
    public var displayName: String {
        switch self {
        case .english:           return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// The corresponding `Locale`, used for `environment(\.locale:)` to instantly relocalize SwiftUI copy.
    public var locale: Locale { Locale(identifier: rawValue) }
}

/// Where speech-to-text (STT) runs: local model vs cloud API.
///
/// `rawValue` is the persisted string and must not be renamed arbitrarily.
public enum STTMode: String, CaseIterable, Identifiable, Sendable {
    /// Local model (e.g. WhisperKit), offline, privacy-first.
    case local
    /// Cloud transcription API (e.g. OpenAI transcribe), requires network and credentials.
    case cloud
    /// Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+). The speech model is a system-managed
    /// asset (installed by the OS, no app download). Only offered in the UI on macOS 26+; below that the picker
    /// filters this case out, so selecting it never leads to an unavailable engine.
    case appleSpeech

    public var id: String { rawValue }

    /// Default STT: local, privacy-first.
    public static let `default`: STTMode = .local

    public var displayName: String {
        switch self {
        case .local:       return "本地模型"
        case .cloud:       return "云端 API"
        case .appleSpeech: return "Apple 语音"
        }
    }

    /// The localization key for the settings-panel Picker display (stored in the App-side `Localizable.xcstrings`).
    /// The view renders with `Text(LocalizedStringKey(localizationKey))`, switching language instantly with `uiLocale`.
    public var localizationKey: String {
        switch self {
        case .local:       return "stt.mode.local"
        case .cloud:       return "stt.mode.cloud"
        case .appleSpeech: return "stt.mode.appleSpeech"
        }
    }
}

/// Polish style: determines the leaning of the polish instructions sent to the LLM (see design Spec Section 6.2).
///
/// The style only affects the wording of the "register / cleanup intensity" segment of the system prompt,
/// without changing the hard constraints in Section 6.1 (only cleanup not answering, removing filler words, fidelity, etc.).
///
/// `rawValue` is the persisted string and must not be renamed arbitrarily.
public enum PolishStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Smart (default): the full cleanup -- remove filler words, add punctuation, fix self-corrections, bullet-point when necessary, adjust register by App name, preserving spoken naturalness.
    case smart
    /// Punctuation only: only add punctuation and capitalization, remove the most obvious filler words; do not restructure sentences, bullet-point, or change wording (most faithful).
    case punctuationOnly
    /// Formal written: on top of "smart", switch to a written / formal register (de-colloquialized, complete sentences).
    case formal
    /// Casual: on top of "smart", keep a natural spoken rhythm (suitable for messaging / chatting), with light cleanup.
    case casual

    public var id: String { rawValue }

    /// Default polish style: smart polish.
    public static let `default`: PolishStyle = .smart

    public var displayName: String {
        switch self {
        case .smart:           return "智能润色"
        case .punctuationOnly: return "仅补标点"
        case .formal:          return "正式书面"
        case .casual:          return "轻松随意"
        }
    }

    /// The localization key for the settings-panel Picker display (stored in the App-side `Localizable.xcstrings`).
    /// The view renders with `Text(LocalizedStringKey(localizationKey))`, switching language instantly with `uiLocale`.
    public var localizationKey: String {
        switch self {
        case .smart:           return "polish.style.smart"
        case .punctuationOnly: return "polish.style.punctuationOnly"
        case .formal:          return "polish.style.formal"
        case .casual:          return "polish.style.casual"
        }
    }
}

/// The kind of large-model Provider used for polish.
///
/// Covers only the Providers sayit currently supports; `rawValue` is the persisted string (also used as the display name),
/// **changing it makes old config unreadable**, so it must stay consistent with history. The model list and default models are centralized here as a single source of truth.
public enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case anthropic = "Anthropic"
    case chatGPT = "ChatGPT 登录"

    public var id: String { rawValue }

    /// Default Provider: ChatGPT (Codex login).
    public static let `default`: ProviderKind = .chatGPT

    /// Display name for interpolation: brand names are returned verbatim (identical across both languages), ChatGPT drops the login suffix persisted in `rawValue`.
    ///
    /// Used only for `%@` interpolation in `polish.apiKeyField`/`polish.keySaved`, etc.; these messages only appear for brand Providers with an API Key
    /// (OpenAI / DeepSeek / Anthropic), ChatGPT goes through OAuth and is never fetched here.
    /// The Picker label switches to ``localizationKey`` (localized per `uiLocale`) and no longer uses this value.
    public var displayName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .deepSeek:  return "DeepSeek"
        case .anthropic: return "Anthropic"
        case .chatGPT:   return "ChatGPT"
        }
    }

    /// The localization key for the settings-panel Picker display (stored in the App-side `Localizable.xcstrings`).
    /// Brand names are identical across both languages; only the ChatGPT login item is localized per `uiLocale` (English "ChatGPT login" / the Chinese login label).
    /// The view renders with `Text(LocalizedStringKey(localizationKey))`.
    public var localizationKey: String {
        switch self {
        case .openAI:    return "provider.openAI"
        case .deepSeek:  return "provider.deepSeek"
        case .anthropic: return "provider.anthropic"
        case .chatGPT:   return "provider.chatGPT"
        }
    }

    /// Selectable models for this Provider: (id sent to the API, label displayed). The model ids
    /// below are the bare, current ids verified 2026-06 against each vendor's live API; the labels
    /// are brand product names that are identical in English and Simplified Chinese, so they are
    /// rendered verbatim (no localization-catalog key needed). The per-Provider default is defined
    /// separately in `defaultModel` (it is not necessarily the first item).
    public var modelOptions: [(id: String, label: String)] {
        switch self {
        case .openAI:
            // OpenAI API-key provider: current GPT-5.x chat models, bare ids (no date suffix).
            // Legacy gpt-4o / gpt-4o-mini were removed (deprecated). Default is gpt-5.4-mini
            // (cost-effective for the polish task), see `defaultModel`.
            return [("gpt-5.5", "GPT-5.5"),
                    ("gpt-5.4-mini", "GPT-5.4 mini"),
                    ("gpt-5-mini", "GPT-5 mini")]
        case .deepSeek:
            // DeepSeek API: the current V4 models. The legacy deepseek-chat / deepseek-reasoner ids
            // are deprecated (sunset 2026-07-24) and were removed. Default is V4 Flash
            // (faster/cheaper, best for the polish task), see `defaultModel`.
            return [("deepseek-v4-flash", "DeepSeek V4 Flash"),
                    ("deepseek-v4-pro", "DeepSeek V4 Pro")]
        case .anthropic:
            // Anthropic: current Claude 4.x models, bare ids (no date suffix). Legacy claude-3.x ids
            // were removed. Default is Haiku 4.5 (cheap/fast, best for the polish task), see
            // `defaultModel`.
            return [("claude-haiku-4-5", "Claude Haiku 4.5"),
                    ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
                    ("claude-opus-4-8", "Claude Opus 4.8")]
        case .chatGPT:
            // ChatGPT-login (Codex) Responses API only accepts the Codex model set tied to the
            // logged-in ChatGPT account; legacy ids (gpt-4o / gpt-4o-mini) now return HTTP 400
            // "model is not supported when using Codex with a ChatGPT account". The ids below were
            // confirmed against the live Codex models endpoint and verified with a real HTTP 200
            // from the Responses API. Default is GPT-5.5 (the current frontier model, first item).
            // Note: "Pro" variants are not exposed to this Codex login (they return HTTP 400), so
            // they are intentionally omitted to keep every offered model actually usable.
            return [("gpt-5.5", "GPT-5.5"),
                    ("gpt-5.4", "GPT-5.4"),
                    ("gpt-5.4-mini", "GPT-5.4 mini")]
        }
    }

    /// The default model for this Provider. For the polish text task the API-key Providers lean
    /// toward the lightweight/cheap model rather than always the first (frontier) item; the
    /// ChatGPT login keeps the frontier GPT-5.5 first item. Always one of `modelOptions` (guarded by
    /// `testEveryProviderDefaultIsAValidOption`), so a stale stored id clamps to a real, usable model.
    public var defaultModel: String {
        switch self {
        case .openAI:    return "gpt-5.4-mini"
        case .deepSeek:  return "deepseek-v4-flash"
        case .anthropic: return "claude-haiku-4-5"
        case .chatGPT:   return "gpt-5.5"
        }
    }
}
