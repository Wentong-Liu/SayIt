import Foundation

/// Resolves user-facing copy in the app's currently-selected UI language (``AppConfig/uiLanguage``),
/// not the system locale.
///
/// ## Why this exists
/// The UI-language override is applied through SwiftUI's `.environment(\.locale, …)`, which only
/// redirects `Text(LocalizedStringKey)` resolution. Strings built imperatively with
/// `String(localized:)` ignore that environment and resolve against the **system** locale, so on a
/// Chinese-system Mac with Display Language = English the recording HUD pill, the Permissions pane,
/// and the microphone-test copy stayed Chinese while the rest of the UI was English.
///
/// This helper loads the chosen language's `.lproj` table out of the supplied bundle and reads the
/// value directly from it, so imperatively-built copy matches the rest of the UI and switches live
/// with the setting. It never crashes and never returns the bare key:
/// - the language code comes from ``UILanguage/lprojName`` (`en` / `zh-Hans`), which is exactly the
///   compiled `.lproj` directory name;
/// - if that `.lproj` (or its `Localizable.strings`) can't be resolved — e.g. a SwiftPM test bundle
///   that ships the raw `.xcstrings`, or a garbled language — it falls back to the normal
///   `String(localized:)` resolution, and if even that returns the bare key, to `defaultValue`.
public enum UILanguageLocalizer {
    /// Resolves `key` in the given UI `language` against `bundle`, falling back safely.
    ///
    /// - Parameters:
    ///   - key: the localization key (e.g. `"hud.listening"`).
    ///   - defaultValue: English fallback used only if neither the `.lproj` lookup nor the normal
    ///     `String(localized:)` resolution yields a real (non-key) value. Never returns the bare key.
    ///   - table: the `.strings` table name (`nil` == the default `Localizable` table).
    ///   - bundle: where the compiled `.lproj` resources live (`Bundle.module` for SayItCore copy,
    ///     `Bundle.main` for the app's copy).
    ///   - language: the target UI language. Production callers use the live convenience overload
    ///     ``string(_:defaultValue:table:bundle:)`` instead; this explicit form is for tests.
    /// - Returns: the value in `language`, or a safe fallback. Guaranteed non-empty and never the key.
    public static func string(
        _ key: String,
        defaultValue: String,
        table: String? = nil,
        bundle: Bundle,
        language: UILanguage
    ) -> String {
        if let path = bundle.path(forResource: language.lprojName, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            // `value:` is a sentinel: when the key is absent the bundle returns it verbatim, letting
            // us detect a miss and fall through to the normal resolution below.
            let sentinel = "\u{0}__SayIt_missing__"
            let resolved = langBundle.localizedString(forKey: key, value: sentinel, table: table)
            if resolved != sentinel { return resolved }
        }

        // Fallback: normal system resolution (the previous behavior). `String(localized:)` returns the
        // bare key when nothing matches, so clamp that to `defaultValue`.
        let systemResolved = String(localized: String.LocalizationValue(key), table: table, bundle: bundle)
        return systemResolved == key ? defaultValue : systemResolved
    }

    /// Convenience that resolves against the **live** persisted UI-language setting.
    ///
    /// Reads ``AppConfig/persistedUILanguage(_:)`` (a nonisolated `UserDefaults` read, the same value
    /// `AppConfig.shared.uiLanguage` returns), so it is callable from both the main actor (the settings
    /// panes, which re-evaluate it when ``SettingsViewModel`` republishes the change) and nonisolated
    /// contexts (the HUD's `RecordingState.displayText`, rebuilt each dictation). Re-reads each call, so
    /// copy switches live when the user changes the language.
    public static func string(
        _ key: String,
        defaultValue: String,
        table: String? = nil,
        bundle: Bundle
    ) -> String {
        string(key, defaultValue: defaultValue, table: table, bundle: bundle,
               language: AppConfig.persistedUILanguage())
    }
}

public extension UILanguage {
    /// The compiled `.lproj` directory name for this language (identical to the persisted ``rawValue``:
    /// `en` / `zh-Hans`). Used by ``UILanguageLocalizer`` to load the per-language strings table.
    var lprojName: String { rawValue }
}
