import SwiftUI
import SayItCore

/// 「通用」分区：触发键、交互模式、识别语言。
struct GeneralSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("触发键", selection: $viewModel.triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }

                Picker("交互方式", selection: $viewModel.interactionMode) {
                    ForEach(InteractionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(interactionHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("触发")
            }

            Section {
                Picker("识别语言", selection: $viewModel.language) {
                    ForEach(viewModel.languageOptions, id: \.code) { option in
                        Text(option.label).tag(option.code)
                    }
                }
            } header: {
                Text("语言")
            } footer: {
                Text("选择「自动检测」让识别引擎根据语音判断语言。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var interactionHint: String {
        switch viewModel.interactionMode {
        case .hold:   return "按住触发键开始录音，松开结束。"
        case .toggle: return "单击触发键开始录音，再次单击结束。"
        }
    }
}

#Preview {
    GeneralSettingsView(viewModel: SettingsViewModel())
        .frame(width: 480, height: 420)
}
