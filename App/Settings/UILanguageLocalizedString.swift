import Foundation
import SayItCore

/// Resolves an app-catalog key in the currently-selected UI language (``AppConfig/uiLanguage``),
/// not the system locale.
///
/// The settings panes build copy imperatively with `String(localized:)`, which ignores the
/// `.environment(\.locale, …)` override and resolves against the **system** locale — so on a
/// Chinese-system Mac with Display Language = English the Permissions pane and the microphone-test
/// copy stayed Chinese. This thin wrapper around ``UILanguageLocalizer`` reads from the app bundle's
/// (`Bundle.main`) per-language `.lproj` table instead, matching the rest of the UI. The panes
/// re-render when `uiLanguage` changes (``SettingsViewModel`` republishes it on the config-change
/// notification), so each call re-evaluates and the copy switches live.
///
/// Safe by construction: it never returns the bare key and never crashes — it falls back to the
/// normal `String(localized:)` resolution and then to `defaultValue` when the `.lproj`/key is missing.
func uiLanguageLocalized(_ key: String, defaultValue: String) -> String {
    UILanguageLocalizer.string(key, defaultValue: defaultValue, bundle: .main)
}

/// Format variant: resolves a `printf`-style format key in the selected UI language, then substitutes
/// `arguments`. Used for the "System Default (%@)" device label, where the wrapper text must follow the
/// UI language but the interpolated macOS-provided device name is inserted verbatim.
func uiLanguageLocalized(format key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
    let format = UILanguageLocalizer.string(key, defaultValue: defaultValue, bundle: .main)
    return String(format: format, arguments: arguments)
}
