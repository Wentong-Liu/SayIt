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

            if let message = viewModel.credentialStatusMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    STTSettingsView(viewModel: SettingsViewModel())
        .frame(width: 480, height: 420)
}
