import SwiftUI
import SayItCore

/// 「语音识别（STT）」分区：本地/云端切换、本地模型选择、云端模型 + API Key 录入。
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
            } footer: {
                Text(viewModel.sttMode == .local
                     ? "stt.footer.local"
                     : "stt.footer.cloud")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch viewModel.sttMode {
            case .local:
                Section("stt.section.localModel") {
                    Picker("stt.model", selection: $viewModel.localModel) {
                        ForEach(viewModel.localModelOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    modelStatusRow
                }
            case .cloud:
                Section("stt.section.cloud") {
                    Picker("stt.transcribeModel", selection: $viewModel.cloudSTTModel) {
                        ForEach(viewModel.cloudSTTModelOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    SecureField("stt.cloudAPIKeyField", text: $viewModel.cloudSTTAPIKey)
                        .onSubmit { viewModel.saveCloudSTTAPIKey() }

                    Button("stt.saveKey") { viewModel.saveCloudSTTAPIKey() }
                        .disabled(viewModel.cloudSTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let message = viewModel.sttStatusMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            viewModel.reloadCredentials()
            // 进入页面时按当前模型的本地缓存实况刷新下载状态。
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

    /// 本地模型「下载状态」行：未下载 / 下载中（进度 + 速度 + 取消）/ 已下载（重新下载）/ 失败（重试）。
    /// 观察 ``SettingsViewModel/localModelState``（其源为 `@Observable` 的 `ModelManager.state`）。
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
            // 直接展示真实失败原因（不止 tooltip），便于用户/支持定位（网络、解析、文件不齐等）。
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    STTSettingsView(viewModel: SettingsViewModel())
        .frame(width: 480, height: 420)
}
