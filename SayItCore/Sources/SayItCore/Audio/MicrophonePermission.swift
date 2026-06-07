import AVFoundation
import Foundation

/// 麦克风权限的当前状态（对 `AVAuthorizationStatus` 的简化封装，便于上层判断）。
public enum MicrophoneAuthorization: Sendable, Equatable {
    /// 尚未询问过用户，可调用 `MicrophonePermission.request()` 触发系统弹窗。
    case notDetermined
    /// 用户已授权。
    case authorized
    /// 用户拒绝，或被家长控制/MDM 等限制。需引导用户去系统设置开启。
    case denied
    /// 系统策略限制（无法通过设置变更）。
    case restricted

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }
}

/// 麦克风权限请求/查询的封装。
///
/// 使用 `AVCaptureDevice`（音频设备）的授权 API：macOS 上配合应用 Info.plist 的
/// `NSMicrophoneUsageDescription` 使用。首次 `request()` 会弹出系统授权对话框。
public enum MicrophonePermission {
    /// 当前麦克风授权状态（不触发弹窗）。
    public static var current: MicrophoneAuthorization {
        MicrophoneAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// 请求麦克风权限。
    ///
    /// - 若状态为 `.notDetermined`，弹出系统授权对话框并等待用户选择。
    /// - 若已授权/已拒绝，则直接返回当前结果而不弹窗（系统行为）。
    /// - 返回 `true` 表示已获授权。
    public static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 请求权限并返回结构化状态（请求后重新查询，能区分 denied/restricted）。
    public static func requestStatus() async -> MicrophoneAuthorization {
        _ = await request()
        return current
    }
}
