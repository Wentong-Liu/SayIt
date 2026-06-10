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
                    .settingsCaption()
            }

            if viewModel.polishEnabled {
                // Persistent setup CTA / warning: shown whenever polish is ENABLED but not yet set up for
                // the current provider (ChatGPT not signed in, or a BYO provider with no saved API key).
                // The copy matches the provider (sign-in vs API-key). This is the pane's persistent CTA —
                // distinct from the transient `polishStatusMessage` Section below — and reacts to provider /
                // enable / login / key-save because every input is observable VM state.
                if let warningKey = viewModel.polishSetupWarningKey {
                    Section {
                        Label(LocalizedStringKey(warningKey), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                }

                Section {
                    Picker("polish.style", selection: $viewModel.polishStyle) {
                        ForEach(PolishStyle.allCases) { style in
                            Text(LocalizedStringKey(style.localizationKey)).tag(style)
                        }
                    }
                } header: {
                    Text("polish.section.style")
                        .settingsSectionHeader()
                }

                Section {
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
                } header: {
                    Text("polish.section.model")
                        .settingsSectionHeader()
                }

                Section {
                    if viewModel.providerUsesOAuth {
                        chatGPTCredentialView
                    } else {
                        apiKeyCredentialView
                    }
                } header: {
                    Text("polish.section.credentials")
                        .settingsSectionHeader()
                }

                if let message = viewModel.polishStatusMessage {
                    Section {
                        Text(message)
                            .settingsCaption()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsFormTypography()
        .onAppear {
            // Clear a stale status line from a previous visit, and refresh credentials WITHOUT clobbering an
            // unsaved key the user may have typed before the pane last disappeared (the view model lives for
            // the whole SettingsView, so onAppear can re-run with a dirty buffer).
            viewModel.clearStatusMessages()
            viewModel.reloadCredentialsIfClean()
        }
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
        // Persistent key-presence status, mirroring the OAuth sign-in row: green when a key is saved,
        // amber warning when empty (so the user knows polish will be skipped). Reactive — `polishBYOKeyPresent`
        // tracks the same Keychain-backed buffer the SecureField below binds to (never logs the key).
        HStack {
            Image(systemName: viewModel.polishBYOKeyPresent ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(viewModel.polishBYOKeyPresent ? .green : .orange)
            Text(viewModel.polishBYOKeyPresent ? "polish.apiKeySet" : "polish.apiKeyMissing")
        }

        SecureField(uiLanguageLocalized(format: "polish.apiKeyField %@",
                                        defaultValue: "%@ API Key", viewModel.providerKind.displayName),
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
