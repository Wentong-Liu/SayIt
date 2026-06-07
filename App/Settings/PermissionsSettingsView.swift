import SwiftUI
import SayItCore

/// 「权限」分区：展示麦克风与辅助功能授权状态，并提供「去系统设置」引导。
///
/// 状态查询复用 `SayItCore` 已有助手（``MicrophonePermission`` / ``HotkeyManager/isProcessTrusted``），
/// 不在此处新造权限判定逻辑。
struct PermissionsSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: "麦克风",
                    detail: "录制语音用于识别。",
                    granted: viewModel.microphoneStatus == .authorized,
                    statusText: microphoneStatusText,
                    actionTitle: microphoneActionTitle
                ) {
                    Task { await viewModel.requestMicrophone() }
                }

                permissionRow(
                    title: "辅助功能",
                    detail: "监听全局触发键并把文本注入当前 App。",
                    granted: viewModel.accessibilityTrusted,
                    statusText: viewModel.accessibilityTrusted ? "已授权" : "未授权",
                    actionTitle: "去系统设置"
                ) {
                    viewModel.openAccessibilitySettings()
                }
            } header: {
                Text("授权状态")
            } footer: {
                Text("在系统设置中更改授权后，请返回此页面刷新状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("刷新状态") { viewModel.refreshPermissions() }
            }
        }
        .formStyle(.grouped)
        .onAppear { viewModel.refreshPermissions() }
    }

    private var microphoneStatusText: String {
        switch viewModel.microphoneStatus {
        case .authorized:    return "已授权"
        case .denied:        return "已拒绝"
        case .restricted:    return "受限制"
        case .notDetermined: return "未询问"
        }
    }

    /// 未决时按钮发起系统弹窗；否则引导去系统设置。
    private var microphoneActionTitle: String {
        viewModel.microphoneStatus == .notDetermined ? "请求授权" : "去系统设置"
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        statusText: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(granted ? .green : .secondary)
            }

            Spacer()

            if !granted {
                Button(actionTitle, action: action)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    PermissionsSettingsView(viewModel: SettingsViewModel())
        .frame(width: 480, height: 420)
}
