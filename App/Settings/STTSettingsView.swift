import SwiftUI
import SayItCore

/// The "Speech Recognition (STT)" section: local/cloud switch, local model selection, cloud model + API Key entry.
struct STTSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("stt.engine", selection: $viewModel.sttMode) {
                    ForEach(STTMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("stt.section.engine")
                    .settingsSectionHeader()
            } footer: {
                Text(viewModel.sttMode == .local
                     ? "stt.footer.local"
                     : "stt.footer.cloud")
                    .settingsCaption()
            }

            switch viewModel.sttMode {
            case .local:
                Section {
                    // The local model is fixed to large-v3-turbo (the recommended sweet spot); there is no
                    // longer a picker. Show it as a static labeled line so the user knows which model the
                    // Download/Re-download row below acts on. The localized `model.large-v3-turbo` value
                    // ("large-v3-turbo (recommended)") follows the chosen UI language.
                    LabeledContent("stt.model") {
                        Text("model.large-v3-turbo")
                    }

                    modelStatusRow
                } header: {
                    Text("stt.section.localModel")
                        .settingsSectionHeader()
                }
            case .cloud:
                Section {
                    Picker("stt.transcribeModel", selection: $viewModel.cloudSTTModel) {
                        ForEach(viewModel.cloudSTTModelOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    SecureField("stt.cloudAPIKeyField", text: $viewModel.cloudSTTAPIKey)
                        .onSubmit { viewModel.saveCloudSTTAPIKey() }

                    Button("stt.saveKey") { viewModel.saveCloudSTTAPIKey() }
                        .disabled(viewModel.cloudSTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("stt.section.cloud")
                        .settingsSectionHeader()
                }
            }

            if let message = viewModel.sttStatusMessage {
                Section {
                    Text(message)
                        .settingsCaption()
                }
            }
        }
        .formStyle(.grouped)
        .settingsFormTypography()
        .onAppear {
            viewModel.reloadCredentials()
            // On entering the page, refresh the download state per the current model's actual local cache.
            viewModel.refreshLocalModelState()
        }
    }

    /// Formats a bytes/sec value into a human-readable size string (e.g. "1.2 MB"), to
    /// which we append "/s" at the call site. KB/MB/GB units keep the readout compact;
    /// `.binary` count style matches how download sizes are conventionally shown.
    private static let speedFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        return formatter
    }()

    /// The local model "download state" row: not downloaded / downloading (progress + speed + cancel) / downloaded (re-download) / failed (retry).
    /// Observes ``SettingsViewModel/localModelState`` (whose source is the `@Observable` `ModelManager.state`).
    @ViewBuilder
    private var modelStatusRow: some View {
        switch viewModel.localModelState {
        case .notDownloaded:
            LabeledContent("stt.downloadStatus") {
                HStack(spacing: 8) {
                    Text("stt.notDownloaded").foregroundStyle(.secondary)
                    Button("stt.download") {
                        Task { await viewModel.downloadLocalModel() }
                    }
                }
            }

        case .downloading(let progress, let speedBytesPerSec):
            LabeledContent("stt.downloadStatus") {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    // Live speed beside the percentage, available once we have a sample.
                    // Rendered verbatim because ByteCountFormatter already produces a
                    // locale-aware string (e.g. "1.2 MB"); we append "/s" to make it a
                    // rate. Using verbatim avoids adding a new Localizable.xcstrings key
                    // (the catalog is outside this change's scope).
                    if let speedBytesPerSec {
                        Text(verbatim: Self.speedFormatter.string(fromByteCount: Int64(speedBytesPerSec)) + "/s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button("stt.cancel") { viewModel.cancelLocalModelDownload() }
                }
            }

        case .downloaded:
            LabeledContent("stt.downloadStatus") {
                HStack(spacing: 8) {
                    Label("stt.downloaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                    Button("stt.redownload") {
                        Task { await viewModel.downloadLocalModel(force: true) }
                    }
                }
            }

        case .failed(let reason):
            LabeledContent("stt.downloadStatus") {
                HStack(spacing: 8) {
                    Label("stt.downloadFailed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .labelStyle(.titleAndIcon)
                    Button("stt.retry") {
                        Task { await viewModel.downloadLocalModel() }
                    }
                }
                .help(reason)
            }
            // Directly show the real failure reason (not just a tooltip), to help the user/support pinpoint it (network, parsing, incomplete files, etc.).
            Text(reason)
                .font(Theme.Typography.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    STTSettingsView(viewModel: SettingsViewModel())
        .frame(width: 480, height: 420)
}
