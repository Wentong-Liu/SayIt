import SwiftUI
import SayItCore

/// 「润色」分区：开关、风格、Provider 与模型选择，以及凭据
/// （ChatGPT 登录按钮走 OAuth / 各 Provider 的 API Key 录入）。
struct PolishSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 润色", isOn: $viewModel.polishEnabled)
            } footer: {
                Text("关闭后直接注入原始识别文本，不做整理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if viewModel.polishEnabled {
                Section("风格") {
                    Picker("润色风格", selection: $viewModel.polishStyle) {
                        ForEach(PolishStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }

                Section("模型") {
                    Picker("Provider", selection: $viewModel.providerKind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .onChange(of: viewModel.providerKind) { _, _ in
                        viewModel.providerDidChange()
                    }

                    Picker("模型", selection: $viewModel.model) {
                        ForEach(viewModel.providerKind.modelOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                }

                Section("凭据") {
                    if viewModel.providerUsesOAuth {
                        chatGPTCredentialView
                    } else {
                        apiKeyCredentialView
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
        }
        .formStyle(.grouped)
        .onAppear { viewModel.reloadCredentials() }
    }

    /// ChatGPT OAuth 登录/登出。
    @ViewBuilder
    private var chatGPTCredentialView: some View {
        HStack {
            Image(systemName: viewModel.isChatGPTLoggedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                .foregroundStyle(viewModel.isChatGPTLoggedIn ? .green : .secondary)
            Text(viewModel.isChatGPTLoggedIn ? "已登录 ChatGPT" : "未登录")
            Spacer()
            if viewModel.isChatGPTLoggedIn {
                Button("退出登录") { viewModel.logoutChatGPT() }
            } else {
                Button {
                    viewModel.loginWithChatGPT()
                } label: {
                    if viewModel.isLoggingIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("用 ChatGPT 登录")
                    }
                }
                .disabled(viewModel.isLoggingIn)
            }
        }
    }

    /// 普通 Provider 的 API Key 录入。
    @ViewBuilder
    private var apiKeyCredentialView: some View {
        SecureField("\(viewModel.providerKind.displayName) API Key", text: $viewModel.polishAPIKey)
            .onSubmit { viewModel.savePolishAPIKey() }

        Button("保存密钥") { viewModel.savePolishAPIKey() }
            .disabled(viewModel.polishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

#Preview {
    PolishSettingsView(viewModel: SettingsViewModel())
        .frame(width: 480, height: 420)
}
