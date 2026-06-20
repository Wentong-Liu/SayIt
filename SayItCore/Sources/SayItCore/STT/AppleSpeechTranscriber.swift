import AVFoundation
import Foundation
import Speech
import os

// AppleSpeechTranscriber — the third STT backend, alongside local WhisperKit and the cloud API.
//
// What it is:
// - macOS 26+ ONLY. It wraps Apple's `SpeechAnalyzer` + `SpeechTranscriber` (the `Speech` framework's
//   on-device, system-managed dictation engine introduced in macOS 26 / iOS 26). Construction is gated by
//   `@available(macOS 26, *)`; the coordinator only ever builds it behind a `#available(macOS 26, *)` check.
//
// Key behaviors that differ from the other two backends:
// - SYSTEM-MANAGED MODELS, NO APP DOWNLOAD. Unlike WhisperKit (the app downloads a HuggingFace snapshot via
//   `ModelManager`), the speech assets here are installed by the OS via `AssetInventory.assetInstallationRequest`.
//   We only check `SpeechTranscriber.installedLocales` and trigger a `downloadAndInstall()` when the resolved
//   locale is missing. There is no app-side download UI to wire up.
// - NO CUSTOM-VOCABULARY / PROMPT BIASING. `SpeechTranscriber` exposes no recognition-time term-biasing API
//   (the analysis-context `contextualStrings` surface is intentionally not used here to keep the batch path
//   simple and additive). So the user-dictionary **Layer 1** biasing terms in `options.biasTerms` are a NO-OP
//   here — we never throw on them, and the downstream post-processing dictionary layers still apply to the text
//   this engine returns.
// - BATCH via a one-shot `AsyncStream`. The whole `[Float]` buffer is already in memory (record-then-transcribe),
//   so we yield exactly one `AnalyzerInput`, finish the stream, then `finalizeAndFinishThroughEndOfInput()` and
//   drain `transcriber.results`. With no `volatileResults` reporting option every emitted `Result` is final, so
//   we concatenate their `text` (an `AttributedString`) in order.
//
// Concurrency: implemented as an `actor`. `SpeechAnalyzer` / `SpeechTranscriber` and the per-call
// `AVAudioConverter` are NOT `Sendable`; they are created, used, and dropped entirely inside `transcribe(...)`
// and never escape the actor's isolation, satisfying Swift 6 strict concurrency.

/// On-device speech transcription backed by Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+).
///
/// See the file header for the design notes (system-managed assets, no custom-vocabulary biasing, one-shot
/// batch via `AsyncStream`). Conforms to the existing ``Transcriber`` protocol and maps results/errors into
/// this module's ``TranscriptionResult`` / ``STTError``, so it slots in next to ``WhisperKitTranscriber`` and
/// ``CloudTranscriber`` with no change to the rest of the pipeline.
@available(macOS 26, *)
public actor AppleSpeechTranscriber: Transcriber {
    /// Lightweight observability logger (same subsystem/category as the local engine; no text is ever logged).
    private nonisolated static let log = Logger(subsystem: SayItCore.identifier, category: "stt")

    /// The default language hint (a BCP-47 / ISO code such as `"en"` / `"zh"`, or a full id like `"zh_CN"`).
    /// `nil` means "follow `Locale.current`". A per-call `language` argument overrides this; this hint is the
    /// fallback used when the call passes `nil`.
    private let defaultLanguage: String?

    /// Creates an Apple-speech transcriber.
    ///
    /// - Parameter language: a default language hint. Dictation auto-detection upstream passes `nil` per call,
    ///   in which case this hint (or `Locale.current`) decides which locale's model is used.
    public init(language: String? = nil) {
        self.defaultLanguage = language
    }

    // MARK: - Transcriber

    public func transcribe(
        _ audio: [Float],
        sampleRate: Double,
        language: String?,
        options: TranscribeOptions
    ) async throws -> TranscriptionResult {
        // Empty audio -> empty-text result (mirrors the contract; no engine work needed). Note: WhisperKit throws
        // `.emptyAudio` here, but the spec for this backend asks for an empty-text result on empty input.
        guard !audio.isEmpty else {
            return TranscriptionResult(text: "")
        }

        // Apple's Speech framework gates SpeechAnalyzer on speech-recognition authorization (and the
        // NSSpeechRecognitionUsageDescription Info.plist string). Request it lazily here; a denied/restricted
        // status maps to `.notReady` so the coordinator shows its "configure" hint instead of the framework
        // failing mid-transcription (or the process trapping on a missing usage-description string).
        try await Self.ensureAuthorized()

        // `options.biasTerms` is intentionally ignored: SpeechTranscriber has no recognition-time custom-vocabulary
        // API, so Layer-1 biasing is a no-op here (the downstream dictionary post-processing layers still run on the
        // returned text). We deliberately do NOT throw on a non-empty term list.

        let resolvedLocale = await Self.resolveLocale(requested: language ?? defaultLanguage)

        do {
            // Build the transcriber module first: it doubles as the "supporting module" for the asset-installation
            // request, and is the module both `SpeechAnalyzer(modules:)` and `bestAvailableAudioFormat` operate on.
            let transcriber = Self.makeTranscriber(locale: resolvedLocale)

            // Install the system speech assets for this locale if they are not already present (OS-managed; this is
            // NOT an app-side download). Idempotent: when the locale is already installed `installIfNeeded` is a no-op.
            try await Self.installIfNeeded(locale: resolvedLocale, transcriber: transcriber)

            let analyzer = SpeechAnalyzer(modules: [transcriber])

            // Convert the incoming mono float PCM to the format the analyzer wants for this module set, then feed it
            // as a single `AnalyzerInput` through a one-shot stream.
            let inputBuffer = try await Self.makeInputBuffer(
                from: audio,
                sourceSampleRate: sampleRate,
                modules: [transcriber]
            )

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            continuation.yield(AnalyzerInput(buffer: inputBuffer))
            continuation.finish()

            try await analyzer.start(inputSequence: stream)
            // Flush everything queued through end-of-input and finish the run, so `results` completes.
            try await analyzer.finalizeAndFinishThroughEndOfInput()

            // With no `volatileResults` reporting option, every emitted result is final; concatenate their text.
            var pieces: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if !text.isEmpty { pieces.append(text) }
            }

            let joined = pieces.joined()
            let duration = sampleRate > 0 ? Double(audio.count) / sampleRate : nil
            return TranscriptionResult(
                text: Self.normalize(joined),
                segments: [],
                duration: duration
            )
        } catch let error as STTError {
            throw error
        } catch {
            throw STTError.transcriptionFailed(reason: String(describing: error))
        }
    }

    /// Ready when the resolved default locale's system speech model is already installed (no download would block).
    public var isReady: Bool {
        get async {
            let locale = await Self.resolveLocale(requested: defaultLanguage)
            return await Self.isInstalled(locale)
        }
    }

    /// Installs the default-locale system speech asset if it is missing. Idempotent (a no-op when already installed).
    /// Maps any failure to ``STTError/transcriptionFailed(reason:)``.
    public func preload() async throws {
        try await Self.ensureAuthorized()
        let locale = await Self.resolveLocale(requested: defaultLanguage)
        do {
            let transcriber = Self.makeTranscriber(locale: locale)
            try await Self.installIfNeeded(locale: locale, transcriber: transcriber)
        } catch let error as STTError {
            throw error
        } catch {
            throw STTError.transcriptionFailed(reason: String(describing: error))
        }
    }

    // MARK: - Locale resolution

    /// Resolves a requested language hint to a concrete `Locale` that `SpeechTranscriber` supports.
    ///
    /// Strategy (best-effort, never throws): start from the requested id (or `Locale.current` when `nil`), expand
    /// bare short codes (`"zh"` -> `zh_CN`, `"en"` -> `en_US`, etc.), then match against
    /// `SpeechTranscriber.supportedLocales` by exact id, then by language code; fall back to `en_US`. Asking for a
    /// locale that turns out to be unsupported simply falls back rather than failing the whole transcription.
    static func resolveLocale(requested: String?) async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales

        // Treat "auto"/empty/nil as "no explicit request" -> follow the system locale (auto-detect is upstream).
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate: Locale = (trimmed.isEmpty || trimmed.lowercased() == "auto")
            ? Locale.current
            : Locale(identifier: Self.expandShortCode(trimmed))

        guard !supported.isEmpty else { return candidate }

        // 1) Exact identifier match (handles full ids like "zh_CN", "en_US").
        let candidateID = candidate.identifier
        if let exact = supported.first(where: { $0.identifier == candidateID }) {
            return exact
        }
        // 2) Same language code (e.g. requested "en_GB" or bare "en" -> first supported "en_*").
        if let lang = candidate.language.languageCode?.identifier,
           let byLanguage = supported.first(where: { $0.language.languageCode?.identifier == lang }) {
            return byLanguage
        }
        // 3) Fall back to en_US when present, else the first supported locale (keeps recognition usable).
        if let english = supported.first(where: { $0.identifier == "en_US" }) {
            return english
        }
        return supported.first ?? candidate
    }

    /// Expands a bare short language code to a concrete region-qualified id matching `SpeechTranscriber`'s catalog
    /// (e.g. `"zh"` -> `"zh_CN"`, `"en"` -> `"en_US"`). A code that already carries a region/script (contains `-`
    /// or `_`) is returned unchanged. Unknown short codes are returned as-is and resolved by the language-code match.
    static func expandShortCode(_ code: String) -> String {
        if code.contains("-") || code.contains("_") { return code }
        switch code.lowercased() {
        case "zh": return "zh_CN"
        case "en": return "en_US"
        case "ja": return "ja_JP"
        case "ko": return "ko_KR"
        case "fr": return "fr_FR"
        case "de": return "de_DE"
        case "es": return "es_ES"
        case "it": return "it_IT"
        case "pt": return "pt_BR"
        case "yue": return "zh_HK"
        default: return code
        }
    }

    /// Whether the given locale's speech model is already installed on the system.
    static func isInstalled(_ locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier == locale.identifier }) { return true }
        // Fall back to language-code equivalence: `installedLocales` may report a regionally-different but
        // language-equivalent locale that still serves the request.
        if let lang = locale.language.languageCode?.identifier {
            return installed.contains { $0.language.languageCode?.identifier == lang }
        }
        return false
    }

    // MARK: - Authorization

    /// Ensures the app holds Speech-recognition authorization before any SpeechAnalyzer work.
    ///
    /// SpeechAnalyzer / SpeechTranscriber sit on the same Speech-framework authorization as `SFSpeechRecognizer`
    /// and the `NSSpeechRecognitionUsageDescription` Info.plist string. We request it lazily (the system prompts
    /// once on `.notDetermined`, then caches the answer). A non-authorized outcome maps to ``STTError/notReady``
    /// so the coordinator surfaces its "configure" hint instead of the framework failing mid-transcription.
    static func ensureAuthorized() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw STTError.notReady }
        case .denied, .restricted:
            throw STTError.notReady
        @unknown default:
            throw STTError.notReady
        }
    }

    // MARK: - Module + assets

    /// Builds a batch/offline `SpeechTranscriber` for the locale: empty reporting options => NO volatile results
    /// (every emitted result is final), no extra attributes (we only need the text). Pure factory, no I/O.
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    /// Installs the system speech assets needed for `transcriber` (this locale) if they are not already present.
    ///
    /// System-managed: `AssetInventory.assetInstallationRequest(supporting:)` returns `nil` when nothing needs
    /// installing (already satisfied) — in that case this is a no-op. Otherwise it kicks off `downloadAndInstall()`.
    /// Skips the request entirely when `installedLocales` already covers this locale, so warm calls do no work.
    static func installIfNeeded(locale: Locale, transcriber: SpeechTranscriber) async throws {
        if await isInstalled(locale) { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Audio format conversion

    /// Builds the `AVAudioPCMBuffer` to feed the analyzer: wraps the incoming mono float PCM in its source format,
    /// then converts to the analyzer's preferred format (via `AVAudioConverter`) when they differ.
    ///
    /// - Parameters:
    ///   - audio: mono PCM float samples (range ~[-1, 1]).
    ///   - sourceSampleRate: the sample rate of `audio` (≈16k for this app's record-then-transcribe path).
    ///   - modules: the analyzer module set, used to query `bestAvailableAudioFormat`.
    static func makeInputBuffer(
        from audio: [Float],
        sourceSampleRate: Double,
        modules: [any SpeechModule]
    ) async throws -> AVAudioPCMBuffer {
        guard sourceSampleRate > 0 else {
            throw STTError.unsupportedFormat
        }
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw STTError.unsupportedFormat
        }

        let sourceBuffer = try Self.makeFloatBuffer(from: audio, format: sourceFormat)

        // The analyzer tells us the best input format for this module set. If it is unavailable or already matches
        // the source, feed the source buffer directly; otherwise convert with `AVAudioConverter`.
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules),
              targetFormat != sourceFormat else {
            return sourceBuffer
        }
        return try Self.convert(sourceBuffer, to: targetFormat)
    }

    /// Fills an `AVAudioPCMBuffer` (the given `Float32` mono format) from a `[Float]` sample array.
    static func makeFloatBuffer(from audio: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(audio.count)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData else {
            throw STTError.transcriptionFailed(reason: "failed to allocate input audio buffer")
        }
        buffer.frameLength = frameCount
        audio.withUnsafeBufferPointer { src in
            // Single (mono) channel: copy the samples straight in.
            channel[0].update(from: src.baseAddress!, count: audio.count)
        }
        return buffer
    }

    /// Converts a PCM buffer to `targetFormat` using `AVAudioConverter` (handles sample-rate and layout changes the
    /// analyzer may require, e.g. resampling 16k -> the model's native rate). The converter is created and consumed
    /// here so it never escapes the actor.
    static func convert(_ source: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            throw STTError.transcriptionFailed(reason: "failed to create audio converter")
        }
        // Size the output buffer for the resampled frame count (ceil to avoid truncating the tail).
        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 1
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw STTError.transcriptionFailed(reason: "failed to allocate converted audio buffer")
        }

        // One-shot input: hand the whole source buffer over on the first pull, then signal end-of-stream.
        // `AVAudioConverter`'s input block is typed `@Sendable`, but it captures the non-Sendable source buffer and
        // a "already consumed" flag and actually runs synchronously on this thread inside `convert(...)` — there is
        // no real cross-thread sharing. We park both in one `@unchecked Sendable` box so the capture is clean under
        // Swift 6 strict concurrency.
        let pull = OneShotInput(source: source)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if pull.consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            pull.consumed = true
            inputStatus.pointee = .haveData
            return pull.source
        }

        if let conversionError {
            throw STTError.transcriptionFailed(reason: "audio conversion failed: \(conversionError.localizedDescription)")
        }
        if status == .error {
            throw STTError.transcriptionFailed(reason: "audio conversion failed")
        }
        return output
    }

    // MARK: - Text

    /// Trims surrounding whitespace and collapses internal runs of whitespace into single spaces (the per-result
    /// `AttributedString` text fragments can introduce stray edge spaces when concatenated).
    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Device-capability probe for the Apple speech engine, callable on **any** macOS version.
///
/// This lives outside ``AppleSpeechTranscriber`` on purpose: that actor is `@available(macOS 26, *)`, so any
/// member of it would itself be macOS-26-gated and therefore unreachable from the first-run code that must run
/// (and answer "no") on older systems. This namespace is un-gated, performs the `#available` check internally,
/// and returns `false` below macOS 26 — so callers can probe unconditionally.
public enum AppleSpeechSupport {
    /// Whether this device can actually run the Apple speech engine.
    ///
    /// Two conditions must hold: the OS is macOS 26+ (the `Speech` framework's `SpeechTranscriber` exists), AND
    /// the device reports a non-empty `SpeechTranscriber.supportedLocales`. That catalog is empty on macOS 26
    /// machines that lack the speech engine (e.g. unsupported hardware), so an empty list means the API is in
    /// the SDK but not usable here. Returns `false` on macOS < 26.
    ///
    /// Used at first-run to decide whether to prefer `.appleSpeech` as the default engine (and thereby skip the
    /// WhisperKit auto-download). `static` and stateless — it reads only framework state, no actor isolation.
    public static func isSupported() async -> Bool {
        guard #available(macOS 26, *) else { return false }
        return !(await SpeechTranscriber.supportedLocales).isEmpty
    }
}

/// Carries the single source buffer and a one-time "already consumed" flag for `AVAudioConverter`'s `@Sendable`
/// input block.
///
/// Marked `@unchecked Sendable` deliberately: the block runs synchronously on the calling thread inside
/// `AVAudioConverter.convert(to:error:withInputFrom:)` (it is not dispatched concurrently), so the non-Sendable
/// `AVAudioPCMBuffer` and the mutable flag are never actually shared across threads. This box exists only to make
/// that fact explicit to the compiler and keep the conversion path warning-clean under Swift 6.
@available(macOS 26, *)
private final class OneShotInput: @unchecked Sendable {
    let source: AVAudioPCMBuffer
    var consumed = false
    init(source: AVAudioPCMBuffer) { self.source = source }
}
