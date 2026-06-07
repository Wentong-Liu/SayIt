import Observation
import SwiftUI
import SayItCore

/// 「通用」设置页里「麦克风」区的视图模型：承载设备列表、当前选中设备、
/// 以及「测试麦克风」的实时电平采集状态。
///
/// 与 ``SettingsViewModel`` 解耦（本任务不改它），自管一个独立的 ``AudioRecorder``
/// 仅用于测试采集——测试时 `start()` 选定设备、订阅 `levels` 流，把归一化电平切回
/// `@MainActor` 更新 ``level`` 供 VU 电平条绑定；停止/离开页面则停。
///
/// 选中设备写入 ``AppConfig/inputDeviceUID``（`nil` = 跟随系统默认）。
@MainActor
@Observable
final class MicTestViewModel {
    /// 注入的配置；默认 `.shared`，预览/单测可传独立实例。
    @ObservationIgnored private let config: AppConfig

    /// 仅供「测试麦克风」用的录音器（与端到端听写的录音器互不影响）。
    @ObservationIgnored private let recorder: AudioRecording

    /// 后台消费 `levels` 流的任务；停止测试时取消。
    @ObservationIgnored private var levelTask: Task<Void, Never>?

    /// 可选输入设备列表（含「系统默认」选项由 UI 单独呈现）。
    private(set) var devices: [AudioInputDevice] = []

    /// 系统当前默认输入设备 UID（用于在下拉里标注「（系统默认）」）。
    private(set) var systemDefaultUID: String?

    /// 是否正在进行麦克风测试采集。
    private(set) var isTesting: Bool = false

    /// 最新归一化输入电平（0...1），供电平条绑定。停止后回 0。
    private(set) var level: Double = 0

    /// UI 选中的设备 UID；`nil` 表示「系统默认」。
    /// setter 写回 ``AppConfig/inputDeviceUID``；若正在测试则用新设备重启采集。
    var selectedUID: String? {
        get { config.inputDeviceUID }
        set {
            config.inputDeviceUID = newValue
            if isTesting {
                // 切设备即时生效：重启测试采集到新设备。
                restartTesting()
            }
        }
    }

    /// - Parameters:
    ///   - config: 注入配置；默认 `.shared`。
    ///   - recorder: 注入录音器；默认新建 ``AudioRecorder``（单测可传假实现）。
    init(config: AppConfig = .shared, recorder: AudioRecording = AudioRecorder()) {
        self.config = config
        self.recorder = recorder
    }

    /// 刷新可选设备列表与系统默认设备（进入页面或设备插拔后调用）。
    func refreshDevices() {
        devices = AudioInputDeviceManager.availableInputDevices()
        systemDefaultUID = AudioInputDeviceManager.defaultInputDeviceUID()
    }

    /// 切换测试开关（按钮点一下：未测则开始，正在测则停止）。
    func toggleTesting() {
        if isTesting {
            stopTesting()
        } else {
            startTesting()
        }
    }

    /// 开始用选定设备采集并实时刷新电平。已在测试中则忽略。
    func startTesting() {
        guard !isTesting else { return }
        isTesting = true
        let deviceUID = config.inputDeviceUID
        levelTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(deviceUID: deviceUID)
            } catch {
                // 启动失败（无权限/设备忙）：复位状态，电平归零。
                await MainActor.run {
                    self.isTesting = false
                    self.level = 0
                }
                return
            }
            // 订阅电平流；归一化值切回 MainActor 更新 UI。流在 stop() 后会产出 0 并保持有效。
            for await value in self.recorder.levels {
                if Task.isCancelled { break }
                await MainActor.run { self.level = value }
            }
        }
    }

    /// 停止测试采集，电平归零。未在测试则忽略。
    func stopTesting() {
        guard isTesting else { return }
        isTesting = false
        level = 0
        levelTask?.cancel()
        levelTask = nil
        Task { [recorder] in
            // stop() 在未录音时会抛 .notRecording；测试场景下忽略即可。
            _ = try? await recorder.stop()
        }
    }

    /// 用当前选定设备重启测试采集（切设备时调用）。
    private func restartTesting() {
        stopTesting()
        startTesting()
    }

    /// 离开页面时调用：确保停止采集，避免后台一直占用麦克风。
    func onDisappear() {
        stopTesting()
    }
}
