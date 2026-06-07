import Foundation

/// Polish context: injects target-App information to help the model judge register (see design Spec Section 6.1.8).
///
/// For example, when the target App is Xcode it leans toward a technical / code-comment tone, Mail toward an email tone,
/// Slack toward a messaging tone. Only used as a tone / format hint; it does not change the hard constraints in Section 6.1.
public struct PolishContext: Equatable, Sendable {
    /// Display name of the current frontmost App (e.g. "Xcode" / "Mail" / "Slack"). nil when it cannot be obtained.
    public let appName: String?
    /// Bundle identifier of the current frontmost App (e.g. "com.apple.dt.Xcode"). Optional, used for more precise judgment.
    public let bundleId: String?

    public init(appName: String? = nil, bundleId: String? = nil) {
        self.appName = appName
        self.bundleId = bundleId
    }
}
