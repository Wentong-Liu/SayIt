import Foundation

/// 录音过程中可能发生的错误。
public enum AudioRecordingError: Error, Sendable {
    /// 未获得麦克风权限（被拒绝/受限/用户未授权）。
    case microphonePermissionDenied
    /// 已经在录音中，重复调用 `start()`。
    case alreadyRecording
    /// 当前没有在录音，却调用了 `stop()`。
    case notRecording
    /// 无法为输入流构建目标格式的转换器（采样率/声道转换失败）。
    case converterUnavailable
    /// AVAudioEngine 启动失败，附带底层错误描述。
    case engineStartFailed(String)
}

extension AudioRecordingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .microphonePermissionDenied:
            return "AudioRecordingError.microphonePermissionDenied"
        case .alreadyRecording:
            return "AudioRecordingError.alreadyRecording"
        case .notRecording:
            return "AudioRecordingError.notRecording"
        case .converterUnavailable:
            return "AudioRecordingError.converterUnavailable"
        case let .engineStartFailed(message):
            return "AudioRecordingError.engineStartFailed(\(message))"
        }
    }
}

/// 麦克风录音抽象：开始采集、停止并取回累积的 Float32 单声道 16kHz 样本。
///
/// 设计为协议，便于上层（听写流水线）依赖抽象、单测时替换为假实现，
/// 也方便后续替换底层采集方案而不影响调用方。
///
/// 约定：`stop()` 返回的样本即为 `AudioFormat`（16kHz / 单声道 / Float32）。
public protocol AudioRecording: Sendable {
    /// 开始录音（用系统默认输入设备）。若未授权会先尝试请求权限；仍未授权则抛
    /// `.microphonePermissionDenied`。已在录音时抛 `.alreadyRecording`。
    func start() async throws

    /// 用指定输入设备开始录音。
    ///
    /// - Parameter deviceUID: 目标输入设备 UID（``AudioInputDevice/uid``）；
    ///   传 `nil` 等价于 ``start()``（系统默认设备）。
    ///   若 UID 解析不到设备（已拔出/失效），自动回落到系统默认设备。
    /// 其余行为与 ``start()`` 一致（权限、16kHz/mono/Float32、levels 流）。
    func start(deviceUID: String?) async throws

    /// 停止录音并返回本次累积的全部样本（16kHz / 单声道 / Float32）。
    /// 未在录音时抛 `.notRecording`。
    @discardableResult
    func stop() async throws -> [Float]

    /// 是否正在录音。
    var isRecording: Bool { get async }

    /// 实时输入电平流：每段采集缓冲产出一个归一化 RMS 电平（0...1）。
    ///
    /// 供 HUD 波形/音量指示消费（`for await level in recorder.levels { ... }`）。
    /// 录音停止后不再产出新值；跨多次录音持续有效（同一长生命周期流）。
    /// 0 表示静音，1 表示接近满量程。具体映射由实现决定（可含对数压缩以贴合听感）。
    var levels: AsyncStream<Double> { get }
}

public extension AudioRecording {
    /// 默认实现：用系统默认输入设备开始录音（转发到 `start(deviceUID: nil)`）。
    /// 既保证既有调用方 `start()` 不变，也让仅实现 `start(deviceUID:)` 的类型自动获得它。
    func start() async throws {
        try await start(deviceUID: nil)
    }
}
