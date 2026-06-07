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
                    title: String(localized: "perm.microphone", defaultValue: "Microphone"),
                    detail: String(localized: "perm.microphone.detail", defaultValue: "Records your voice for transcription."),
                    granted: viewModel.microphoneStatus == .authorized,
                    statusText: microphoneStatusText,
                    actionTitle: microphoneActionTitle
                ) {
                    Task { await viewModel.requestMicrophone() }
                }

                permissionRow(
                    title: String(localized: "perm.accessibility", defaultValue: "Accessibility"),
                    detail: String(localized: "perm.accessibility.detail",
                                   defaultValue: "Listens for the global trigger key and inserts text into the current app."),
                    granted: viewModel.accessibilityTrusted,
                    statusText: viewModel.accessibilityTrusted
                        ? String(localized: "perm.status.granted", defaultValue: "Granted")
                        : String(localized: "perm.status.notGranted", defaultValue: "Not granted"),
                    actionTitle: String(localized: "perm.openSettings", defaultValue: "Open System Settings")
                ) {
                    viewModel.openAccessibilitySettings()
                }
            } header: {
                Text("perm.section.status")
            } footer: {
                Text("perm.footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("perm.refresh") { viewModel.refreshPermissions() }
            }
        }
        .formStyle(.grouped)
        .onAppear { viewModel.refreshPermissions() }
    }

    private var microphoneStatusText: String {
        switch viewModel.microphoneStatus {
        case .authorized:    return String(localized: "perm.status.granted", defaultValue: "Granted")
        case .denied:        return String(localized: "perm.status.denied", defaultValue: "Denied")
        case .restricted:    return String(localized: "perm.status.restricted", defaultValue: "Restricted")
        case .notDetermined: return String(localized: "perm.status.notAsked", defaultValue: "Not asked")
        }
    }

    /// 未决时按钮发起系统弹窗；否则引导去系统设置。
    private var microphoneActionTitle: String {
        viewModel.microphoneStatus == .notDetermined
            ? String(localized: "perm.requestAccess", defaultValue: "Request Access")
            : String(localized: "perm.openSettings", defaultValue: "Open System Settings")
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
