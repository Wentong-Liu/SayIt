import SwiftUI
import SayItCore

/// 「润色」分区：开关、风格、Provider 与模型选择，以及凭据
/// （ChatGPT 登录按钮走 OAuth / 各 Provider 的 API Key 录入）。
struct PolishSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("polish.enable", isOn: $viewModel.polishEnabled)
            } footer: {
                Text("polish.enable.footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if viewModel.polishEnabled {
                Section("polish.section.style") {
                    Picker("polish.style", selection: $viewModel.polishStyle) {
                        ForEach(PolishStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }

                Section("polish.section.model") {
                    Picker("polish.provider", selection: $viewModel.providerKind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .onChange(of: viewModel.providerKind) { _, _ in
                        viewModel.providerDidChange()
                    }

                    Picker("polish.model", selection: $viewModel.model) {
                        ForEach(viewModel.providerKind.modelOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                }

                Section("polish.section.credentials") {
                    if viewModel.providerUsesOAuth {
                        chatGPTCredentialView
                    } else {
                        apiKeyCredentialView
                    }
                }

                if let message = viewModel.polishStatusMessage {
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
            Text(viewModel.isChatGPTLoggedIn ? "polish.loggedIn" : "polish.notLoggedIn")
            Spacer()
            if viewModel.isChatGPTLoggedIn {
                Button("polish.signOut") { viewModel.logoutChatGPT() }
            } else {
                Button {
                    viewModel.loginWithChatGPT()
                } label: {
                    if viewModel.isLoggingIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("polish.signInWithChatGPT")
                    }
                }
                .disabled(viewModel.isLoggingIn)
            }
        }
    }

    /// 普通 Provider 的 API Key 录入。
    @ViewBuilder
    private var apiKeyCredentialView: some View {
        SecureField(String(localized: "polish.apiKeyField \(viewModel.providerKind.displayName)"),
                    text: $viewModel.polishAPIKey)
            .onSubmit { viewModel.savePolishAPIKey() }

        Button("polish.saveKey") { viewModel.savePolishAPIKey() }
            .disabled(viewModel.polishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

#Preview {
    PolishSettingsView(viewModel: SettingsViewModel())
        .frame(width: 480, height: 420)
}
