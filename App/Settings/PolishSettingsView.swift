import SwiftUI
import SayItCore

/// The "Polish" section: toggle, style, Provider and model selection, and credentials
/// (the ChatGPT login button goes through OAuth / API Key entry for each Provider).
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
                            Text(LocalizedStringKey(style.localizationKey)).tag(style)
                        }
                    }
                }

                Section("polish.section.model") {
                    Picker("polish.provider", selection: $viewModel.providerKind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(LocalizedStringKey(kind.localizationKey)).tag(kind)
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

    /// ChatGPT OAuth login/logout.
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

    /// API Key entry for ordinary Providers.
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
