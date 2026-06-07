import SwiftUI
import SayItCore

/// 「通用」分区：触发键、交互模式、麦克风（设备选择 + 测试电平）、识别语言。
struct GeneralSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    /// 麦克风测试状态（设备列表 / 选中设备 / 实时电平）。与 `SettingsViewModel` 解耦。
    @State private var micVM = MicTestViewModel()

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
                Picker("输入设备", selection: $micVM.selectedUID) {
                    Text(defaultDeviceLabel).tag(String?.none)
                    ForEach(micVM.devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }

                HStack {
                    Button(micVM.isTesting ? "停止测试" : "测试麦克风") {
                        micVM.toggleTesting()
                    }
                    MicLevelBar(level: micVM.level)
                }

                Text(micHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("麦克风")
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
        .onAppear { micVM.refreshDevices() }
        .onDisappear { micVM.onDisappear() }
    }

    /// 「系统默认」项的展示名，附带当前默认设备名（若可知）。
    private var defaultDeviceLabel: String {
        if let uid = micVM.systemDefaultUID,
           let device = micVM.devices.first(where: { $0.uid == uid }) {
            return "系统默认（\(device.name)）"
        }
        return "系统默认"
    }

    private var micHint: String {
        micVM.isTesting
            ? "对着麦克风说话，电平条会随音量跳动。"
            : "点击「测试麦克风」检查所选设备是否有输入。"
    }

    private var interactionHint: String {
        switch viewModel.interactionMode {
        case .hold:   return "按住触发键开始录音，松开结束。"
        case .toggle: return "单击触发键开始录音，再次单击结束。"
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
        .accessibilityLabel("麦克风输入电平")
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
