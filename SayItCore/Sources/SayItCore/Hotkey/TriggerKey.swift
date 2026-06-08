import AppKit

/// The global hotkey that triggers voice dictation.
///
/// Currently supports the independent left/right keys of Command / Option / Control, plus a reserved Fn/Globe key.
/// Shift is deliberately excluded -- it is far too easy to trigger accidentally via double-tap/hold while typing.
///
/// `keyCode` is each modifier key's hardware scan code; `modifierFlag` is the corresponding modifier flag,
/// used in `.flagsChanged` events to judge the "down" edge (that flag is set at this moment).
public enum TriggerKey: String, CaseIterable, Identifiable, Sendable {
    case rightCommand
    case leftCommand
    case rightOption
    case leftOption
    case rightControl
    case leftControl
    /// Fn / Globe key. On newer macOS it is an independent modifier key.
    /// Reserved: the hardware keyCode is unstable (varies by model/keyboard), the event layer should rely on the `.function` flag.
    case fnGlobe

    public var id: String { rawValue }

    /// Default trigger key: the right Option (sits under the right thumb/hand and rarely conflicts with common shortcuts).
    public static let `default`: TriggerKey = .rightOption

    /// The modifier key's hardware keyCode.
    ///
    /// Fn/Globe's physical keycode varies by model; here we give the common 0x3F(63) on macOS,
    /// but event-layer decisions should prefer `modifierFlag == .function` and not hard-depend on this code.
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

    /// The corresponding modifier flag: this flag is set when the key is pressed.
    public var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightCommand, .leftCommand:  return .command
        case .rightOption, .leftOption:    return .option
        case .rightControl, .leftControl:  return .control
        case .fnGlobe:                     return .function
        }
    }

    /// The label used by the settings UI and explanatory copy, e.g. "Right Command".
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

    /// The settings-panel display name (same source as ``label``).
    ///
    /// Retained for compatibility with the config layer's early API naming; new code should prefer ``label``.
    public var displayName: String { label }

    /// The localization key for the settings-panel Picker display (stored in the App-side `Localizable.xcstrings`).
    ///
    /// The Command/Option/Control glyphs are universal; only the "left/right" prefix is localized per `uiLocale`; Fn/Globe is already neutral but also goes through the catalog for consistency.
    /// The view renders with `Text(LocalizedStringKey(localizationKey))`, so the displayed copy switches with the UI language instantly.
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
