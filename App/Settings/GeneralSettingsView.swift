import SwiftUI
import SayItCore

/// 「通用」分区：触发键、交互模式、麦克风（设备选择 + 测试电平）、界面语言。
struct GeneralSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    /// 麦克风测试状态（设备列表 / 选中设备 / 实时电平）。与 `SettingsViewModel` 解耦。
    @State private var micVM = MicTestViewModel()

    var body: some View {
        Form {
            Section {
                Picker("general.triggerKey", selection: $viewModel.triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }

                Picker("general.interactionMode", selection: $viewModel.interactionMode) {
                    ForEach(InteractionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
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

    /// 「系统默认」项的展示名，附带当前默认设备名（若可知）。
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

    private var interactionHint: String {
        switch viewModel.interactionMode {
        case .hold:
            return String(localized: "general.interactionHint.hold",
                          defaultValue: "Hold the trigger key to record, release to stop.")
        case .toggle:
            return String(localized: "general.interactionHint.toggle",
                          defaultValue: "Tap the trigger key to start, tap again to stop.")
        }
    }
}

/// 简易 VU 电平条：用 `level`（0...1）按比例填充，颜色随电平由绿转橙。
///
/// 纯展示组件——不持有任何状态，电平值由上层（``MicTestViewModel/level``）驱动。
private struct MicLevelBar: View {
    /// 归一化电平（0...1）。
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
