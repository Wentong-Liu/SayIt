import SwiftUI
import SayItCore

/// The SayIt settings main interface: paged to carry the four sections "General / Speech Recognition / Polish / Permissions".
///
/// It only does the settings UI and reading/writing config/credentials, binding the existing ``AppConfig`` and ``KeychainStore`` (via ``SettingsViewModel``),
/// without end-to-end dictation orchestration (which belongs to T13). All config enums reuse `SayItCore`'s single source of truth, not redeclared.
struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        TabView {
            GeneralSettingsView(viewModel: viewModel)
                .tabItem { Label("tab.general", systemImage: "gearshape") }

            STTSettingsView(viewModel: viewModel)
                .tabItem { Label("tab.stt", systemImage: "waveform") }

            PolishSettingsView(viewModel: viewModel)
                .tabItem { Label("tab.polish", systemImage: "sparkles") }

            PermissionsSettingsView(viewModel: viewModel)
                .tabItem { Label("tab.permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 420)
    }
}

#Preview {
    SettingsView()
}
