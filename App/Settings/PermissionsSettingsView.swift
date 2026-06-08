import SwiftUI
import SayItCore

/// The "Permissions" section: shows microphone and accessibility authorization status, and provides a "go to System Settings" guide.
///
/// State queries reuse existing helpers in `SayItCore` (``MicrophonePermission`` / ``HotkeyManager/isProcessTrusted``),
/// without creating new permission-decision logic here.
struct PermissionsSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: uiLanguageLocalized("perm.microphone", defaultValue: "Microphone"),
                    detail: uiLanguageLocalized("perm.microphone.detail", defaultValue: "Records your voice for transcription."),
                    granted: viewModel.microphoneStatus == .authorized,
                    statusText: microphoneStatusText,
                    actionTitle: microphoneActionTitle
                ) {
                    Task { await viewModel.requestMicrophone() }
                }

                permissionRow(
                    title: uiLanguageLocalized("perm.accessibility", defaultValue: "Accessibility"),
                    detail: uiLanguageLocalized("perm.accessibility.detail",
                                                defaultValue: "Listens for the global trigger key and inserts text into the current app."),
                    granted: viewModel.accessibilityTrusted,
                    statusText: viewModel.accessibilityTrusted
                        ? uiLanguageLocalized("perm.status.granted", defaultValue: "Granted")
                        : uiLanguageLocalized("perm.status.notGranted", defaultValue: "Not granted"),
                    actionTitle: uiLanguageLocalized("perm.openSettings", defaultValue: "Open System Settings")
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
        case .authorized:    return uiLanguageLocalized("perm.status.granted", defaultValue: "Granted")
        case .denied:        return uiLanguageLocalized("perm.status.denied", defaultValue: "Denied")
        case .restricted:    return uiLanguageLocalized("perm.status.restricted", defaultValue: "Restricted")
        case .notDetermined: return uiLanguageLocalized("perm.status.notAsked", defaultValue: "Not asked")
        }
    }

    /// When undetermined the button initiates the system prompt; otherwise it guides to System Settings.
    private var microphoneActionTitle: String {
        viewModel.microphoneStatus == .notDetermined
            ? uiLanguageLocalized("perm.requestAccess", defaultValue: "Request Access")
            : uiLanguageLocalized("perm.openSettings", defaultValue: "Open System Settings")
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
