import AppKit
import ApplicationServices

/// Default implementation that injects text at the cursor of the currently focused App.
///
/// Strategy:
/// 1. Capture the target App (NSWorkspace.shared.frontmostApplication).
/// 2. If the AX-enhanced path is enabled and authorized, first try inserting directly via AXUIElementSetAttributeValue; return on success.
/// 3. Otherwise take the default pasteboard path: save the current pasteboard -> write the text -> simulate Cmd-V -> restore the original pasteboard after a delay.
/// 4. If any path fails, the text stays in the pasteboard and it returns .failedTextLeftInPasteboard, so the user can paste manually.
///
/// All dependencies are injected via protocols, and the key pure logic (pasteboard save/restore, target-App capture) is unit-testable.
@MainActor
public final class TextInjector: TextInjecting {
    /// Tunable behavior parameters.
    public struct Configuration: Sendable {
        /// Whether to try AX direct insertion first (enhanced path). Defaults to false: pasteboard paste is more universal and more compatible.
        public var preferAccessibility: Bool
        /// How long to wait after delivering Cmd-V and before restoring the pasteboard. Gives the target App time to read the pasteboard.
        public var restoreDelay: Duration

        public init(preferAccessibility: Bool = false,
                    restoreDelay: Duration = .milliseconds(150)) {
            self.preferAccessibility = preferAccessibility
            self.restoreDelay = restoreDelay
        }

        public static let `default` = Configuration()
    }

    private let configuration: Configuration
    private let pasteboard: PasteboardProtocol
    private let keystroke: KeystrokePosting
    private let frontmostProvider: FrontmostAppProviding
    private let axInserter: AXTextInserting
    /// Wait implementation: defaults to Task.sleep; unit tests can inject an instantly-returning stub to avoid slowing tests.
    private let sleeper: @Sendable (Duration) async -> Void

    public init(
        configuration: Configuration = .default,
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        keystroke: KeystrokePosting = CGEventKeystrokePoster(),
        frontmostProvider: FrontmostAppProviding = WorkspaceFrontmostAppProvider(),
        axInserter: AXTextInserting = AXTextInserter(),
        sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.frontmostProvider = frontmostProvider
        self.axInserter = axInserter
        self.sleeper = sleeper
    }

    /// Synchronous injection entry point (required by the protocol). Empty text is a no-op; everything else is delegated to the internal implementation.
    /// Restoring the pasteboard must run with a delay after Cmd-V, so the delay+restore is placed in an async task of the
    /// current actor (rather than detached); by the time the caller gets the result the paste is delivered and the restore completes shortly after.
    public func inject(_ text: String) -> InjectionResult {
        guard !text.isEmpty else { return .success(method: .pasteboard) }

        guard let target = frontmostProvider.captureTarget() else {
            // No frontmost App: still put the text in the pasteboard so the user can paste manually.
            pasteboard.writeString(text)
            return .failedTextLeftInPasteboard(reason: "无前台 App，无法定位注入目标")
        }

        // Enhanced path: AX direct insertion. On success the pasteboard is left untouched.
        if configuration.preferAccessibility {
            if axInserter.insert(text, into: target) {
                return .success(method: .accessibility)
            }
            // On AX failure, continue to the pasteboard fallback (do not fail outright).
        }

        return injectViaPasteboard(text)
    }

    /// Pasteboard paste path: save -> write -> Cmd-V -> restore after a delay.
    private func injectViaPasteboard(_ text: String) -> InjectionResult {
        let backup = PasteboardBackup.capture(from: pasteboard)
        pasteboard.writeString(text)

        let posted = keystroke.postPaste()
        guard posted else {
            // Cmd-V was not delivered: do not restore; the text stays in the pasteboard for the user to paste manually.
            return .failedTextLeftInPasteboard(reason: "模拟 ⌘V 失败，文本已留在剪贴板")
        }

        // Restore the original pasteboard after a delay, giving the target App time to read the pasteboard.
        // Run asynchronously via Task to avoid blocking the caller; the paste has been delivered at this point.
        scheduleRestore(backup)
        return .success(method: .pasteboard)
    }

    /// Restore the pasteboard after a delay.
    private func scheduleRestore(_ backup: PasteboardBackup) {
        let delay = configuration.restoreDelay
        let pb = pasteboard
        let sleep = sleeper
        Task { @MainActor in
            await sleep(delay)
            backup.restore(to: pb)
        }
    }
}
