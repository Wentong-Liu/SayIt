import AppKit

/// A minimal abstraction providing the "currently focused App", to allow injecting stubs in unit tests.
@MainActor
public protocol FrontmostAppProviding: Sendable {
    /// Snapshot of the current frontmost App, returns nil when there is no frontmost App.
    func captureTarget() -> InjectionTarget?
}

/// Implementation based on NSWorkspace.shared.frontmostApplication.
@MainActor
public final class WorkspaceFrontmostAppProvider: FrontmostAppProviding {
    public init() {}

    public func captureTarget() -> InjectionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InjectionTarget(running: app)
    }
}
