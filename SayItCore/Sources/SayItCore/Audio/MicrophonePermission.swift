import AVFoundation
import Foundation

/// Current microphone permission state (a simplified wrapper over `AVAuthorizationStatus` for easier upper-layer decisions).
public enum MicrophoneAuthorization: Sendable, Equatable {
    /// Not yet asked the user; calling `MicrophonePermission.request()` can trigger the system prompt.
    case notDetermined
    /// The user has granted access.
    case authorized
    /// The user denied, or is restricted by parental controls/MDM, etc. The user must be guided to enable it in System Settings.
    case denied
    /// Restricted by system policy (cannot be changed via Settings).
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

/// Wrapper for microphone permission requests/queries.
///
/// Uses the authorization API of `AVCaptureDevice` (audio device): on macOS it works together with the app's Info.plist
/// `NSMicrophoneUsageDescription`. The first `request()` pops up the system authorization dialog.
public enum MicrophonePermission {
    /// Current microphone authorization status (does not trigger a prompt).
    public static var current: MicrophoneAuthorization {
        MicrophoneAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Request microphone permission.
    ///
    /// - If the status is `.notDetermined`, pops up the system authorization dialog and waits for the user's choice.
    /// - If already authorized/denied, returns the current result directly without a prompt (system behavior).
    /// - Returns `true` if authorized.
    public static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Requests permission and returns a structured status (re-queries after the request, able to distinguish denied/restricted).
    public static func requestStatus() async -> MicrophoneAuthorization {
        _ = await request()
        return current
    }
}
