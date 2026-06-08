import SwiftUI
import SayItCore

/// The SayIt settings main interface: paged to carry the sections "General / Speech Recognition / Polish / Dictionary / Permissions".
///
/// It only does the settings UI and reading/writing config/credentials, binding the existing ``AppConfig`` and ``KeychainStore`` (via ``SettingsViewModel``),
/// without end-to-end dictation orchestration (which belongs to T13). All config enums reuse `SayItCore`'s single source of truth, not redeclared.
struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    /// A single shared user-dictionary store for the Dictionary pane. A default ``DictionaryStore`` points at the
    /// same `dictionary.json` the dictation pipeline reads, so entries added here immediately feed PR-2's rewriter.
    @State private var dictionaryStore = DictionaryStore()

    var body: some View {
        TabView {
            GeneralSettingsView(viewModel: viewModel)
                .tabItem { Label("tab.general", systemImage: "gearshape") }

            STTSettingsView(viewModel: viewModel)
                .tabItem { Label("tab.stt", systemImage: "waveform") }

            PolishSettingsView(viewModel: viewModel)
                .tabItem { Label("tab.polish", systemImage: "sparkles") }

            DictionarySettingsView(store: dictionaryStore, viewModel: viewModel)
                .tabItem { Label("tab.dictionary", systemImage: "character.book.closed") }

            PermissionsSettingsView(viewModel: viewModel)
                .tabItem { Label("tab.permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 420)
    }
}

#Preview {
    SettingsView()
}
