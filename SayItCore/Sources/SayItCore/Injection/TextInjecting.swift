import AppKit

/// Snapshot of the target App for text injection. Captured before injection, usable for diagnostics/logging on a failed-injection fallback.
public struct InjectionTarget: Sendable, Equatable {
    /// Bundle identifier of the target App (may be nil, e.g. for some processes without a bundle).
    public let bundleIdentifier: String?
    /// Localized name of the target App (may be nil).
    public let localizedName: String?
    /// Process ID of the target App.
    public let processIdentifier: pid_t

    public init(bundleIdentifier: String?, localizedName: String?, processIdentifier: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.processIdentifier = processIdentifier
    }

    /// Captures a snapshot from an NSRunningApplication.
    public init(running app: NSRunningApplication) {
        self.bundleIdentifier = app.bundleIdentifier
        self.localizedName = app.localizedName
        self.processIdentifier = app.processIdentifier
    }
}

/// The path used for injection.
public enum InjectionMethod: Sendable, Equatable {
    /// Writes the text directly into the focused element via Accessibility (enhanced path).
    case accessibility
    /// Writes via the pasteboard and simulates a Cmd-V paste (default path).
    case pasteboard
}

/// Injection result.
public enum InjectionResult: Sendable, Equatable {
    /// Injection succeeded. method indicates the path that finally took effect.
    case success(method: InjectionMethod)
    /// Injection failed, but the text was kept in the pasteboard (the user can paste manually).
    /// reason is a human-readable failure cause.
    case failedTextLeftInPasteboard(reason: String)
}

extension InjectionResult {
    /// Whether the injection succeeded.
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Injects a piece of text at the cursor of the currently focused App.
public protocol TextInjecting: Sendable {
    /// Injects text. Returns the injection result; on failure the text is kept in the pasteboard.
    /// - Parameter text: the text to inject. An empty string is treated as a no-op and returns success.
    @MainActor
    func inject(_ text: String) -> InjectionResult
}
