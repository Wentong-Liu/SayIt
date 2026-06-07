import SwiftUI
import SayItCore

/// The "General" section: trigger key, interaction mode, microphone (device selection + test level), UI language.
struct GeneralSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Microphone test state (device list / selected device / live level). Decoupled from `SettingsViewModel`.
    @State private var micVM = MicTestViewModel()

    var body: some View {
        Form {
            Section {
                Picker("general.triggerKey", selection: $viewModel.triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(LocalizedStringKey(key.localizationKey)).tag(key)
                    }
                }

                Picker("general.interactionMode", selection: $viewModel.interactionMode) {
                    ForEach(InteractionMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(interactionHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("general.section.trigger")
            }

            Section {
                Picker("general.inputDevice", selection: $micVM.selectedUID) {
                    Text(defaultDeviceLabel).tag(String?.none)
                    ForEach(micVM.devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }

                HStack {
                    Button(micVM.isTesting
                           ? String(localized: "general.stopTest")
                           : String(localized: "general.testMic")) {
                        micVM.toggleTesting()
                    }
                    MicLevelBar(level: micVM.level)
                }

                Text(micHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("general.section.microphone")
            }

            Section {
                Picker("general.uiLanguage", selection: $viewModel.uiLanguage) {
                    ForEach(viewModel.uiLanguageOptions) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            } header: {
                Text("general.section.interfaceLanguage")
            } footer: {
                Text("general.uiLanguage.footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { micVM.refreshDevices() }
        .onDisappear { micVM.onDisappear() }
    }

    /// The display name of the "System Default" item, with the current default device name attached (if known).
    private var defaultDeviceLabel: String {
        if let uid = micVM.systemDefaultUID,
           let device = micVM.devices.first(where: { $0.uid == uid }) {
            return String(localized: "general.systemDefault.named \(device.name)")
        }
        return String(localized: "general.systemDefault", defaultValue: "System Default")
    }

    private var micHint: String {
        micVM.isTesting
            ? String(localized: "general.micHint.testing",
                     defaultValue: "Speak into the mic — the level bar reacts to volume.")
            : String(localized: "general.micHint.idle",
                     defaultValue: "Tap “Test Microphone” to check the selected device has input.")
    }

    /// The localization key for the interaction-style hint copy. Returns a `LocalizedStringKey` rather than a pre-resolved `String`,
    /// letting `Text(interactionHint)` switch language instantly with `uiLocale` (the environment locale) (consistent with the other Picker copy).
    private var interactionHint: LocalizedStringKey {
        switch viewModel.interactionMode {
        case .singleTap:
            return "general.interactionHint.singleTap"
        case .hold:
            return "general.interactionHint.hold"
        }
    }
}

/// A simple VU level bar: fills proportionally by `level` (0...1), with the color shifting from green to orange as the level rises.
///
/// A pure display component -- holds no state, the level value is driven by the upper layer (``MicTestViewModel/level``).
private struct MicLevelBar: View {
    /// The normalized level (0...1).
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(fillColor)
                    .frame(width: geo.size.width * clampedLevel)
                    .animation(.linear(duration: 0.08), value: clampedLevel)
            }
        }
        .frame(height: 8)
        .accessibilityLabel(Text("general.micLevel.a11y"))
        .accessibilityValue("\(Int(clampedLevel * 100))%")
    }

    private var clampedLevel: Double { min(max(level, 0), 1) }

    private var fillColor: Color {
        clampedLevel > 0.85 ? .orange : .green
    }
}

#Preview {
    GeneralSettingsView(viewModel: SettingsViewModel())
        .frame(width: 480, height: 420)
}
