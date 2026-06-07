import AppKit

/// 触发语音听写的全局热键。
///
/// 当前支持 ⌘ / ⌥ / ⌃ 的左右独立键，外加预留的 Fn/Globe 键。
/// 故意不收 Shift——打字时极易误触双击/按住。
///
/// `keyCode` 为各修饰键的硬件扫描码；`modifierFlag` 为对应的修饰标志，
/// 用于在 `.flagsChanged` 事件里判定「按下」边沿（该标志此刻被 set）。
public enum TriggerKey: String, CaseIterable, Identifiable, Sendable {
    case rightCommand
    case leftCommand
    case rightOption
    case leftOption
    case rightControl
    case leftControl
    /// Fn / 地球键（Globe）。在较新的 macOS 上是独立修饰键。
    /// 预留：硬件 keyCode 不稳定（机型/键盘差异），事件层应以 `.function` 标志为准。
    case fnGlobe

    public var id: String { rawValue }

    /// 默认触发键：右 ⌘（与右手拇指自然落点一致，且不与常用快捷键冲突）。
    public static let `default`: TriggerKey = .rightCommand

    /// 修饰键的硬件 keyCode。
    ///
    /// Fn/Globe 的物理键码随机型变化，这里给出 macOS 上常见的 0x3F(63)，
    /// 但事件层判定时应优先使用 `modifierFlag == .function`，不要硬依赖此码。
    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand:  return 55
        case .rightOption:  return 61
        case .leftOption:   return 58
        case .rightControl: return 62
        case .leftControl:  return 59
        case .fnGlobe:      return 63
        }
    }

    /// 对应的修饰标志：该键按下时此标志被 set。
    public var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightCommand, .leftCommand:  return .command
        case .rightOption, .leftOption:    return .option
        case .rightControl, .leftControl:  return .control
        case .fnGlobe:                     return .function
        }
    }

    /// 设置界面与说明文案用的标签，例如「右⌘」。
    public var label: String {
        switch self {
        case .rightCommand: return "右⌘"
        case .leftCommand:  return "左⌘"
        case .rightOption:  return "右⌥"
        case .leftOption:   return "左⌥"
        case .rightControl: return "右⌃"
        case .leftControl:  return "左⌃"
        case .fnGlobe:      return "Fn / 🌐"
        }
    }

    /// 设置面板展示名（与 ``label`` 同源）。
    ///
    /// 为兼容配置层早期 API 命名而保留；新代码优先用 ``label``。
    public var displayName: String { label }

    /// 设置面板 Picker 展示用的本地化键（落在 App 端 `Localizable.xcstrings`）。
    ///
    /// ⌘/⌥/⌃ 字形通用，仅「左/右」前缀随 `uiLocale` 本地化；Fn/🌐 已中性，亦走 catalog 保持一致。
    /// 视图用 `Text(LocalizedStringKey(localizationKey))` 渲染，故展示文案随界面语言即时切换。
    public var localizationKey: String {
        switch self {
        case .rightCommand: return "triggerKey.rightCommand"
        case .leftCommand:  return "triggerKey.leftCommand"
        case .rightOption:  return "triggerKey.rightOption"
        case .leftOption:   return "triggerKey.leftOption"
        case .rightControl: return "triggerKey.rightControl"
        case .leftControl:  return "triggerKey.leftControl"
        case .fnGlobe:      return "triggerKey.fnGlobe"
        }
    }
}
