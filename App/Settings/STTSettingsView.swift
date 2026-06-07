import SwiftUI
import SayItCore

/// 「语音识别（STT）」分区：本地/云端切换、本地模型选择、云端模型 + API Key 录入。
struct STTSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("识别方式", selection: $viewModel.sttMode) {
                    ForEach(STTMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("识别引擎")
            } footer: {
                Text(viewModel.sttMode == .local
                     ? "本地模型离线运行，隐私优先，首次使用会下载模型。"
                     : "云端 API 需要联网与有效密钥，识别速度依赖网络。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch viewModel.sttMode {
            case .local:
                Section("本地模型") {
                    Picker("模型", selection: $viewModel.localModel) {
                        ForEach(viewModel.localModelOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    modelStatusRow
                }
            case .cloud:
                Section("云端转写") {
                    Picker("转写模型", selection: $viewModel.cloudSTTModel) {
                        ForEach(viewModel.cloudSTTModelOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    SecureField("OpenAI API Key", text: $viewModel.cloudSTTAPIKey)
                        .onSubmit { viewModel.saveCloudSTTAPIKey() }

                    Button("保存密钥") { viewModel.saveCloudSTTAPIKey() }
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

    /// 本地模型「下载状态」行：未下载 / 下载中（进度 + 取消）/ 已下载（重新下载）/ 失败（重试）。
    /// 观察 ``SettingsViewModel/localModelState``（其源为 `@Observable` 的 `ModelManager.state`）。
    @ViewBuilder
    private var modelStatusRow: some View {
        switch viewModel.localModelState {
        case .notDownloaded:
            LabeledContent("下载状态") {
                HStack(spacing: 8) {
                    Text("未下载").foregroundStyle(.secondary)
                    Button("下载") {
                        Task { await viewModel.downloadLocalModel() }
                    }
                }
            }

        case .downloading(let progress):
            LabeledContent("下载状态") {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("取消") { viewModel.cancelLocalModelDownload() }
                }
            }

        case .downloaded:
            LabeledContent("下载状态") {
                HStack(spacing: 8) {
                    Label("已下载", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                    Button("重新下载") {
                        Task { await viewModel.downloadLocalModel(force: true) }
                    }
                }
            }

        case .failed(let reason):
            LabeledContent("下载状态") {
                HStack(spacing: 8) {
                    Label("下载失败", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .labelStyle(.titleAndIcon)
                    Button("重试") {
                        Task { await viewModel.downloadLocalModel() }
                    }
                }
                .help(reason)
            }
        }
    }
}

#Preview {
    STTSettingsView(viewModel: SettingsViewModel())
        .frame(width: 480, height: 420)
}
