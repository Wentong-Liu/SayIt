import SwiftUI
import SayItCore

/// The "Speech Recognition (STT)" section: local/cloud switch, local model selection, cloud model + API Key entry.
struct STTSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("stt.engine", selection: $viewModel.sttMode) {
                    ForEach(Self.availableModes) { mode in
                        // `.appleSpeech` is only present in `availableModes` on macOS 26+ (where it is usable), so it
                        // carries the "(Recommended)" label; the other engines use their plain localized name.
                        Text(LocalizedStringKey(mode == .appleSpeech ? "stt.mode.appleSpeech.recommended" : mode.localizationKey))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                // On macOS < 26 the Apple engine cannot run, so it is intentionally NOT a selectable segment above
                // (the segmented control stays exactly as it was: local / cloud only). Still surface that the engine
                // EXISTS and why it is unavailable, as a non-interactive greyed caption, so the feature is
                // discoverable without misleading the user into thinking they can pick it on this OS.
                if !Self.appleSpeechAvailable {
                    Label("stt.appleSpeech.requires26", systemImage: "apple.logo")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .settingsCaption()
                }
            } header: {
                Text("stt.section.engine")
                    .settingsSectionHeader()
            } footer: {
                Text(LocalizedStringKey(Self.footerKey(for: viewModel.sttMode)))
                    .settingsCaption()
            }

            switch viewModel.sttMode {
            case .local:
                Section {
                    // Persistent in-pane setup CTA: while the local model is not yet usable
                    // (.notDownloaded / .failed) make the required next step obvious. The existing
                    // Download/Retry button below is the action; this just states the requirement.
                    // Hidden once downloading (the progress row already conveys state) or downloaded.
                    setupCTA

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
            case .appleSpeech:
                // Apple's on-device engine uses a SYSTEM-managed speech model: there is no WhisperKit model
                // download/status UI to show and no API key to enter. Just state that no download is needed.
                Section {
                    Label("stt.appleSpeech.note", systemImage: "apple.logo")
                        .labelStyle(.titleAndIcon)
                        .settingsCaption()
                } header: {
                    Text("stt.section.engine")
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
            // Clear a stale status line from a previous visit, and refresh credentials WITHOUT clobbering an
            // unsaved key the user may have typed before the pane last disappeared (the view model lives for
            // the whole SettingsView, so onAppear can re-run with a dirty buffer).
            viewModel.clearStatusMessages()
            viewModel.reloadCredentialsIfClean()
            // On entering the page, refresh the download state per the current model's actual local cache.
            viewModel.refreshLocalModelState()
        }
    }

    /// Whether Apple's SpeechAnalyzer engine can run on this OS — a pure macOS-version gate (26+). Used to decide
    /// whether `.appleSpeech` is a selectable segment vs. a greyed "requires macOS 26" caption. This is the
    /// version-only check the UI needs; the deeper runtime capability probe (`AppleSpeechSupport.isSupported()`,
    /// which also checks the locale catalog) is used only for the first-run *default* decision, not the picker.
    private static var appleSpeechAvailable: Bool {
        if #available(macOS 26, *) { return true } else { return false }
    }

    /// The STT engines offered as selectable segments, in display order. On macOS 26+ `.appleSpeech` is offered
    /// FIRST (it is the recommended default), followed by `.local` / `.cloud`. On older systems `.appleSpeech` is
    /// filtered out of the segmented control entirely (and instead shown as a non-selectable "requires macOS 26"
    /// caption below), so `.local` / `.cloud` behave exactly as before on macOS < 26.
    private static var availableModes: [STTMode] {
        appleSpeechAvailable ? [.appleSpeech, .local, .cloud] : [.local, .cloud]
    }

    /// The localization key for the engine-section footer caption, per selected mode.
    private static func footerKey(for mode: STTMode) -> String {
        switch mode {
        case .local:       return "stt.footer.local"
        case .cloud:       return "stt.footer.cloud"
        case .appleSpeech: return "stt.appleSpeech.note"
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

    /// Formats a download-size estimate into the documented, human-facing string (e.g. "1.6 GB").
    /// `.decimal` count style matches how the download sizes are stated in the README/docs and how
    /// `ModelManager.estimatedDownloadBytes` computes them (decimal GB, 1_600_000_000 -> "1.6 GB"),
    /// so this is kept separate from the `.binary` `speedFormatter` used for the live speed readout.
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        return formatter
    }()

    /// Persistent in-pane setup CTA for the local engine: shown only while the model is not yet usable
    /// (.notDownloaded / .failed), telling the user the required next step. The Download/Retry button in
    /// ``modelStatusRow`` performs the action; this just makes the requirement obvious. It disappears once
    /// the model is downloading (the progress row covers that) or downloaded. Styled prominently (an amber
    /// warning Label) but consistent with the pane.
    @ViewBuilder
    private var setupCTA: some View {
        switch viewModel.localModelState {
        case .notDownloaded, .failed:
            Label("stt.setupCTA.download", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        case .downloading, .downloaded:
            EmptyView()
        }
    }

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
            // Disclose the approximate download size and the network requirement BEFORE the download
            // starts, as a subtle caption. The size is formatted from the existing
            // `ModelManager.estimatedDownloadBytes` estimate (never hardcoded) via the dedicated
            // decimal `sizeFormatter` so it matches the documented sizes (e.g. "1.6 GB").
            Text(uiLanguageLocalized(format: "stt.download.sizeNote %@",
                                     defaultValue: "~%@ · requires a network connection",
                                     Self.sizeFormatter.string(fromByteCount: viewModel.estimatedLocalModelBytes)))
                .settingsCaption()

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
