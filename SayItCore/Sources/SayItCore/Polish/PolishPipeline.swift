import Foundation
import os

/// The "verdict" of one polish: distinguishes polish success, skip-per-config, and failure fallback (carrying an observable reason).
///
/// Design purpose: expands the formerly single `usedFallback` boolean into distinguishable semantics, so callers and logs
/// can tell "skip (user actively disabled / no content)" from "failure fallback (something went wrong)", to optionally give feedback.
/// Whichever branch, ``PolishOutcome/text`` is always directly injectable text -- **never losing the user's words**.
public enum PolishResolution: Equatable, Sendable {
    /// Truly went through model polish and adopted the model output.
    case polished
    /// Skipped polish per config/input, using the original as-is (no network touched).
    case skipped(SkipReason)
    /// The model was called but failed, falling back to the original. Carries a human-readable failure reason (for logging/feedback).
    case failedFallback(reason: String)

    /// The specific reason for skipping polish (none touch the network).
    public enum SkipReason: Equatable, Sendable {
        /// The caller disabled polish (`polishEnabled == false`).
        case disabled
        /// The input is empty / whitespace-only, with nothing to polish.
        case emptyInput
    }
}

/// The result of one polish.
///
/// `text` is always the "directly injectable" final text -- the model's cleaned-up draft on success, the original dictation (trimmed) on failure/skip.
/// Design stance: **never lose the user's words**, any exception falls back to the original, with ``resolution`` indicating what happened.
///
/// Compatibility: retains the two derived booleans `polished` / `usedFallback` (derived from ``resolution``),
/// so existing callers and unit tests need no changes; new code should prefer reading ``resolution`` to distinguish skip from failure fallback.
public struct PolishOutcome: Equatable, Sendable {
    /// The final usable text (already trimmed). The model output on success, the original rawText on fallback.
    public let text: String
    /// This polish's verdict (success / skip / failure fallback).
    public let resolution: PolishResolution

    /// Whether it truly went through model polish (only `.polished` is true).
    public var polished: Bool { resolution == .polished }

    /// Whether it took the fallback (original) path: skip or failure fallback are both true, only `.polished` is false.
    public var usedFallback: Bool { resolution != .polished }

    /// The human-readable reason on failure fallback; nil for other branches (for the caller/log to observe).
    public var failureReason: String? {
        if case let .failedFallback(reason) = resolution { return reason }
        return nil
    }

    public init(text: String, resolution: PolishResolution) {
        self.text = text
        self.resolution = resolution
    }
}

/// The pipeline that polishes raw STT transcription text into a finished draft.
///
/// Flow: assemble `[LLMMessage]` with the existing ``PolishPromptBuilder`` -> call the caller-injected
/// ``LLMProvider/complete(messages:)`` -> return the cleaned-up text (trimmed).
///
/// Dependency inversion: this type **constructs no concrete Provider**, the caller injects the ``LLMProvider``,
/// decoupled from the App-layer ProviderFactory, convenient for TDD inside Core with a Fake.
///
/// Robustness contract (never lose the user's words):
/// - provider throws / times out -> fall back to the original, `polished=false`, `usedFallback=true`;
/// - provider returns empty / whitespace-only -> fall back to the original (same as above);
/// - `polishEnabled == false` -> return the original directly, not calling the provider;
/// - input is empty / whitespace-only -> return the trimmed input directly, not calling the provider.
public struct PolishPipeline: Sendable {

    /// Observability-only logger for polish failure fallbacks (additive: independent of whether the App injects `logFailure`).
    private static let log = Logger(subsystem: SayItCore.identifier, category: "polish")

    /// An optional failure-log callback: called only on a "failure fallback", carrying a human-readable reason.
    /// Defaults to nil (no logging); the App layer can inject printing/reporting for debugging. `@Sendable` to satisfy concurrency safety.
    private let logFailure: (@Sendable (String) -> Void)?

    /// - Parameter logFailure: the log callback on failure fallback (optional).
    public init(logFailure: (@Sendable (String) -> Void)? = nil) {
        self.logFailure = logFailure
    }

    /// Polishes a segment of raw dictation text.
    /// - Parameters:
    ///   - rawText: the raw STT transcription text.
    ///   - context: the target App context (used to judge register), see ``PolishContext``.
    ///   - style: the polish style, see ``PolishStyle``.
    ///   - provider: the large-model Provider injected by the caller, see ``LLMProvider``.
    ///   - polishEnabled: whether to enable polish; when `false` returns the original directly (defaults to `true`).
    ///   - glossary: the relevant subset of user-dictionary entries (Layer 2), forwarded into the prompt builder's
    ///     system prompt. Defaults to empty, in which case the prompt is byte-identical to the glossary-free build.
    /// - Returns: see ``PolishOutcome`` -- `text` is always directly usable text, ``PolishOutcome/resolution`` indicates the branch.
    public func polish(_ rawText: String,
                       context: PolishContext,
                       style: PolishStyle,
                       provider: LLMProvider,
                       polishEnabled: Bool = true,
                       glossary: [DictionaryEntry] = []) async -> PolishOutcome {
        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty input: nothing to polish, take the original directly (trimmed).
        guard !trimmedRaw.isEmpty else {
            return PolishOutcome(text: trimmedRaw, resolution: .skipped(.emptyInput))
        }

        // Polish off: return the original as-is, no network touched.
        guard polishEnabled else {
            return PolishOutcome(text: trimmedRaw, resolution: .skipped(.disabled))
        }

        let messages = PolishPromptBuilder.build(rawText: rawText, context: context, style: style, glossary: glossary)

        do {
            let raw = try await provider.complete(messages: messages)
            let polishedText = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            // Empty response: the model gave no usable text -> fall back to the original, never returning empty.
            guard !polishedText.isEmpty else {
                return fallback(trimmedRaw, reason: "模型返回空响应")
            }

            return PolishOutcome(text: polishedText, resolution: .polished)
        } catch {
            // Throws / times out (CancellationError, etc.) -> fall back to the original.
            return fallback(trimmedRaw, reason: Self.describe(error))
        }
    }

    /// Failure fallback: log the reason (if a logger was injected) and return the `.failedFallback` result carrying the original.
    private func fallback(_ rawText: String, reason: String) -> PolishOutcome {
        Self.log.error("polish failed, fell back to original: \(reason, privacy: .public)")
        logFailure?(reason)
        return PolishOutcome(text: rawText, resolution: .failedFallback(reason: reason))
    }

    /// Compresses any error into a short human-readable string, for logging/feedback.
    private static func describe(_ error: Error) -> String {
        if error is CancellationError { return "润色超时或被取消" }
        if let providerError = error as? ProviderError { return String(describing: providerError) }
        return error.localizedDescription
    }
}
