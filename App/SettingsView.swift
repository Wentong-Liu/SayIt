import SwiftUI
import SayItCore

/// SayIt 设置主界面：分页承载「通用 / 语音识别 / 润色 / 权限」四个分区。
///
/// 仅做设置 UI 与读写配置/凭据，绑定已有 ``AppConfig`` 与 ``KeychainStore``（经 ``SettingsViewModel``），
/// 不做端到端听写编排（属于 T13）。所有配置枚举复用 `SayItCore` 单一真相源，未重复声明。
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
