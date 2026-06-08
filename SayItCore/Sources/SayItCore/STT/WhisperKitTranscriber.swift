import Foundation
import os
import WhisperKit

// Note: WhisperKit itself also defines a class named `TranscriptionResult`, conflicting with this module's
// (SayItCore) struct of the same name; and within this module there is also an enum `SayItCore` (a placeholder namespace)
// that shadows the module name, making it impossible to disambiguate with either a `WhisperKit.` or a `SayItCore.` prefix.
// So this file does not reference WhisperKit's `TranscriptionResult` by name directly:
// type inference captures the return value of `engine.transcribe(...)`, the mapping logic is done inside a closure,
// so that any bare `TranscriptionResult` appearing in this file always refers to this module's type.

/// A local speech transcription implementation based on WhisperKit (Core ML).
///
/// Offline, privacy-first: the model is fetched from HuggingFace on first use at runtime and cached locally,
/// then inference is purely local. The model download is a runtime behavior, not happening during the build/test stage.
///
/// Typical usage:
/// ```swift
/// let stt = WhisperKitTranscriber(model: "large-v3-turbo")
/// try await stt.preload()                       // optional: download and load the model ahead of time
/// let result = try await stt.transcribe(samples, sampleRate: 16_000, language: "en")
/// ```
///
/// Implemented as an `actor`, guaranteeing serial access to the underlying ``WhisperKit`` engine, so it is `Sendable`.
public actor WhisperKitTranscriber: Transcriber {
    /// The expected input sample rate (Hz). WhisperKit requires 16kHz mono PCM.
    public static let requiredSampleRate: Double = 16_000

    /// Lightweight observability logger for local inference timing (no transcription text is ever logged).
    private nonisolated static let log = Logger(subsystem: "com.liuwentong.SayIt", category: "stt")

    /// The model identifier (e.g. `"large-v3-turbo"`, `"base"`, `"small.en"`).
    public nonisolated let model: String

    /// Whether to prewarm the model during loading (reduces first-frame latency, at the cost of higher peak memory and slower loading).
    private let prewarm: Bool

    /// A short, clean PUNCTUATED carrier always prepended to the Whisper prompt context to bias decoding toward
    /// sentence punctuation.
    ///
    /// Why this exists: local Whisper (large-v3-turbo) routinely emits little/no punctuation — a well-documented Whisper
    /// limitation, worse on turbo and worst for Chinese. The community-standard fix is to seed the autoregressive decoder
    /// with a PUNCTUATED initial context so it stays out of its "no-punctuation mode". Our prior prompt was only a bare,
    /// unpunctuated dictionary term list, which if anything reinforced no-punctuation output.
    ///
    /// Design constraints baked into this string (it is the single, trivially-reversible control point — to disable or
    /// tune the punctuation nudge, edit or empty THIS one constant and nothing else needs to change):
    /// - It carries BOTH Chinese sentence punctuation (`。` `，`) and English sentence punctuation (`.` `,`), because
    ///   dictation auto-detects the language from the AUDIO before this prompt-conditioned decode runs, so the carrier
    ///   must cover whichever language was detected. It biases STYLE (punctuation), never LANGUAGE.
    /// - It contains ZERO hyphens and NO word-internal punctuation, so it nudges only SENTENCE punctuation and can never
    ///   push a dictionary term like "Typeless" toward "Type-less".
    /// - It is intentionally tiny (a brief bilingual phrase, ~a dozen word-piece tokens) so it coexists with dictionary
    ///   terms under WhisperKit's 111-token `promptTokens` cap; in the realistic case (terms + carrier <= 111) BOTH
    ///   survive the cap together.
    static let punctuationCarrier = "你好，这是一段示例。Hello, this is an example."

    /// The loaded WhisperKit engine; lazily built on the first ``preload()`` or ``transcribe(_:sampleRate:language:options:)``.
    private var engine: WhisperKit?

    /// Creates a local WhisperKit transcriber.
    ///
    /// - Parameters:
    ///   - model: the model identifier. Defaults to `"large-v3-turbo"`, consistent with ``AppConfig``'s default local model.
    ///   - prewarm: whether to prewarm the model to reduce first-frame latency. Defaults to `false`.
    public init(model: String = "large-v3-turbo", prewarm: Bool = false) {
        self.model = model
        self.prewarm = prewarm
    }

    /// Ensures the model is downloaded and loaded ready.
    ///
    /// The first call triggers a model download from HuggingFace (if not cached locally), then loads it into memory;
    /// repeated calls are idempotent. Recommended to call during idle time before the user's first recording to reduce first-frame latency.
    ///
    /// - Throws: ``STTError/transcriptionFailed(reason:)`` on model download/load failure
    ///   (``loadedEngine()`` uniformly maps the underlying failure to that case, never throwing `notReady`).
    public func preload() async throws {
        _ = try await loadedEngine()
    }

    /// Whether the current model is loaded ready.
    public var isReady: Bool {
        engine != nil
    }

    public func transcribe(
        _ audio: [Float],
        sampleRate: Double,
        language: String?,
        options transcribeOptions: TranscribeOptions
    ) async throws -> TranscriptionResult {
        guard !audio.isEmpty else {
            throw STTError.emptyAudio
        }
        guard sampleRate == Self.requiredSampleRate else {
            throw STTError.unsupportedFormat
        }

        let engine = try await loadedEngine()

        // Prompt biasing: build promptTokens whenever the tokenizer is available (it is nil until the model has loaded —
        // `loadedEngine()` above loads it, but guard defensively so a missing tokenizer simply falls back to no prompt
        // rather than crashing). The prompt is now ALWAYS built (no early return on empty terms): even with zero
        // dictionary terms the punctuation carrier alone is prompted, so the free/local path also gets the punctuation
        // nudge. `promptTokens(from:)` composes the carrier + (verbatim) dictionary terms; see its doc comment.
        let promptTokens: [Int]? = {
            guard let tokenizer = engine.tokenizer else { return nil }
            let tokens = Self.promptTokens(from: transcribeOptions.biasTerms, tokenizer: tokenizer)
            return tokens.isEmpty ? nil : tokens
        }()

        // Observability only: time JUST the WhisperKit decode (two clock reads bracketing the await — nothing else
        // added to the hot path), then emit one parseable .notice line so the README can quantify on-device speed.
        // Only numbers are logged (all `privacy: .public`); the recognized text itself is never interpolated.
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runDecode(engine: engine, audio: audio, language: language, promptTokens: promptTokens)
        let elapsed = clock.now - start
        let clipSeconds = Double(audio.count) / sampleRate
        let inferenceSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let inferenceMs = inferenceSeconds * 1000
        let rtf = clipSeconds > 0 ? inferenceSeconds / clipSeconds : 0
        Self.log.notice(
            "stt: clip=\(clipSeconds, format: .fixed(precision: 2), privacy: .public)s inference=\(inferenceMs, format: .fixed(precision: 0), privacy: .public)ms rtf=\(rtf, format: .fixed(precision: 3), privacy: .public) chars=\(result.text.count, privacy: .public)"
        )

        // WhisperKit issue #372: on large-v3-turbo, a non-nil promptTokens can yield an EMPTY transcription. We already
        // mitigate by setting firstTokenLogProbThreshold to nil when prompting (so the decode loop does not break early),
        // but if the prompted result still comes back empty, re-transcribe ONCE without promptTokens so dictation never
        // silently fails. The prompt is now ALWAYS present (the punctuation carrier rides along even with zero dict
        // terms), so this same #372 safety net uniformly protects the carrier-only path too — no new empty-output path
        // is introduced by making the prompt always-on. It still only fires on an empty result, so non-empty decodes
        // (the overwhelming majority) keep the prompted output unchanged.
        if promptTokens != nil, result.text.isEmpty {
            return try await runDecode(engine: engine, audio: audio, language: language, promptTokens: nil)
        }
        return result
    }

    /// Runs one WhisperKit decode with the given (optional) biasing prompt and maps the result into this module's type.
    ///
    /// Kept private (not static): it touches the WhisperKit engine. Factored out so the prompted decode and the
    /// issue-372 no-prompt fallback decode share one identical mapping path.
    private func runDecode(
        engine: WhisperKit,
        audio: [Float],
        language: String?,
        promptTokens: [Int]?
    ) async throws -> TranscriptionResult {
        let options = Self.makeDecodingOptions(language: language, promptTokens: promptTokens)
        // Do not explicitly annotate the return type, let inference capture WhisperKit's `[TranscriptionResult]`,
        // then within the closure extract each segment into a module-agnostic raw tuple, to avoid the naming ambiguity.
        // `engine.transcribe(...)` throws WhisperKit's own error type, never this module's
        // ``STTError``, so here we only need one catch that uniformly maps any underlying failure to
        // ``STTError/transcriptionFailed(reason:)`` (no longer keeping the never-hit dead branch
        // `catch let error as STTError`).
        do {
            let wkResults = try await engine.transcribe(audioArray: audio, decodeOptions: options)
            let rawSegments: [RawSegment] = wkResults.flatMap { result in
                result.segments.map { seg in
                    RawSegment(text: seg.text, start: Double(seg.start), end: Double(seg.end))
                }
            }
            let joinedText = wkResults.map { $0.text }.joined(separator: " ")
            return Self.mapResult(joinedText: joinedText, segments: rawSegments)
        } catch {
            throw STTError.transcriptionFailed(reason: String(describing: error))
        }
    }

    // MARK: - Internal

    /// Constructs the ``DecodingOptions`` used for one transcription.
    ///
    /// Two unshakable constraints (fixing the regression of "Chinese transcribed/translated into English"):
    /// - `task` is always `.transcribe`: always transcribes speech into "its own language", never `.translate` (translating into English).
    /// - When no language is explicitly specified (`language == nil`), enable `detectLanguage`, letting WhisperKit detect the language before decoding.
    ///   Otherwise, with `language == nil` and `detectLanguage` off, WhisperKit falls back to the default language code `"en"`,
    ///   decoding non-English speech such as Chinese as English (manifesting as being "translated" into English).
    ///
    /// This function is pure, triggers no model download/load, and can be unit-tested standalone.
    ///
    /// User-dictionary Layer 1 biasing (`promptTokens`): when non-nil and non-empty, the tokens are prepended to the
    /// decoder prefill to steer recognition toward the dictionary terms, AND `firstTokenLogProbThreshold` is set to `nil`
    /// to mitigate WhisperKit issue #372 — on large-v3-turbo a prompt can drive the first sampled token's log-prob below
    /// the default threshold (`-1.5`), breaking the decode loop early and yielding an empty transcription. With `nil`
    /// there is no early break. When `promptTokens` is nil/empty everything is byte-identical to today (no prompt,
    /// `firstTokenLogProbThreshold` keeps WhisperKit's `-1.5` default).
    static func makeDecodingOptions(language: String?, promptTokens: [Int]? = nil) -> DecodingOptions {
        let hasPrompt = !(promptTokens?.isEmpty ?? true)
        return DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            promptTokens: hasPrompt ? promptTokens : nil,
            firstTokenLogProbThreshold: hasPrompt ? nil : DecodingOptions().firstTokenLogProbThreshold
        )
    }

    /// Builds biasing `promptTokens` from the always-on punctuation carrier plus the user's canonical dictionary terms.
    ///
    /// The prompt text it tokenizes is composed by ``promptText(forTerms:)`` and is one of:
    /// - **no terms** -> just ``punctuationCarrier`` (already self-punctuated): the local path is still prompted, so the
    ///   free/local user also gets the punctuation nudge;
    /// - **terms present** -> `"<carrier> <comma-joined verbatim terms>."` — the carrier as a SHORT PREFIX, then the
    ///   shared compact glossary (see ``GlossaryPrompt``, most-relevant term LAST), closed by a trailing period. The only
    ///   characters inserted around the terms are the separator space, GlossaryPrompt's `", "` separators, and the final
    ///   `"."`; NO hyphen and no character is ever inserted INSIDE a term, so each term stays exactly its canonical form.
    ///
    /// It then encodes that text with the model's tokenizer, drops any special tokens (`id >= specialTokenBegin`, so only
    /// real word-piece ids remain), and if over `maxTokens` keeps the LAST `maxTokens` (the suffix).
    ///
    /// ORDERING — "carrier first, dict terms last" — is deliberate: WhisperKit keeps the SUFFIX after trimming, so the
    /// dictionary terms (the harder recall problem, ordered most-used LAST) are the highest-priority survivors, and the
    /// short carrier rides along in front. In the realistic case (carrier + terms <= 111) BOTH survive together; only in
    /// the pathological over-cap case does the suffix-keep drop carrier tokens first — an accepted, documented trade
    /// where the most-relevant terms win (punctuation is a soft nudge, term recall is not).
    ///
    /// Because the carrier is always present, the returned list is non-empty for any input (even empty terms), so a
    /// prompt is ALWAYS set downstream. The only path back to `[]` is a tokenizer that encodes the carrier to nothing.
    ///
    /// The default cap is `111`, the real effective limit. WhisperKit internally trims `promptTokens` to
    /// `maxPromptLen = (maxTokenContext / 2) - 1 = (224 / 2) - 1 = 111` before decoding, and it keeps that trim's own
    /// tail. So any cap above 111 here is silently re-truncated by WhisperKit using ITS suffix, defeating the app's
    /// `usageCount`-ascending ordering. Capping at 111 in this builder lets the app's own most-used-LAST suffix decide
    /// which tokens survive, end to end.
    ///
    /// Pure (given a tokenizer) -> unit-testable with a stub `WhisperTokenizer`. Triggers no model download/load itself.
    static func promptTokens(from terms: [String], tokenizer: WhisperTokenizer, maxTokens: Int = 111) -> [Int] {
        let prompt = promptText(forTerms: terms)
        guard !prompt.isEmpty else { return [] }
        let begin = tokenizer.specialTokens.specialTokenBegin
        let encoded = tokenizer.encode(text: prompt).filter { $0 < begin }
        guard encoded.count > maxTokens else { return encoded }
        // Keep the suffix: the most-relevant terms sit at the end of the prompt, so the tail is the highest priority.
        return Array(encoded.suffix(maxTokens))
    }

    /// Composes the bias prompt TEXT: the always-on punctuation carrier prefix plus the (verbatim) dictionary glossary.
    ///
    /// Factored out from ``promptTokens(from:tokenizer:maxTokens:)`` as the single, trivially-reversible seam for the
    /// punctuation feature — it builds the exact string that gets tokenized, so it is directly unit-testable on the
    /// string level (the terms stay verbatim, the carrier is present, no hyphen is ever introduced).
    ///
    /// - no terms -> ``punctuationCarrier`` alone (self-punctuated);
    /// - terms present -> `"<carrier> <GlossaryPrompt.compactList(terms)>."`. The glossary is the shared, verbatim,
    ///   comma-joined, most-relevant-LAST list; the inserted characters are ONLY the separator space and the final
    ///   period — never a character inside any term.
    static func promptText(forTerms terms: [String]) -> String {
        let glossary = GlossaryPrompt.compactList(from: terms.map { GlossaryPrompt.Term(canonical: $0) })
        guard !glossary.isEmpty else { return punctuationCarrier }
        return "\(punctuationCarrier) \(glossary)."
    }

    /// Returns the loaded engine, lazily building it when necessary (including download+load).
    private func loadedEngine() async throws -> WhisperKit {
        if let engine {
            return engine
        }
        // downloadBase is taken explicitly from the single source of truth ``ModelManager/downloadBase``:
        // completely consistent with the root directory ``ModelManager/download(model:)`` writes to, ensuring "downloaded means usable".
        let config = WhisperKitConfig(
            model: ModelManager.variant(for: model),
            downloadBase: ModelManager.downloadBase,
            modelRepo: ModelManager.modelRepo,
            verbose: false,
            prewarm: prewarm,
            load: true,
            download: true
        )
        do {
            let created = try await WhisperKit(config)
            engine = created
            return created
        } catch {
            throw STTError.transcriptionFailed(reason: "模型加载失败：\(String(describing: error))")
        }
    }

    /// An intermediate segment representation decoupled from WhisperKit, for pure mapping and unit testing without referencing WhisperKit types.
    struct RawSegment: Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    /// Maps one transcription's concatenated text and raw segments into this module's ``TranscriptionResult``.
    ///
    /// WhisperKit may return multiple result fragments due to chunking; the caller has already concatenated the text in order and expanded the segments.
    /// This function is pure, does not depend on the model, and can be unit-tested standalone.
    static func mapResult(joinedText: String, segments rawSegments: [RawSegment]) -> TranscriptionResult {
        // First trim leading/trailing whitespace, then collapse consecutive internal whitespace into a single space: during chunked concatenation (` `-separated), each segment's own
        // leading/trailing spaces easily concatenate into double spaces; collapsing once avoids artifacts like "a  b" in the final text.
        let text = Self.collapseWhitespace(joinedText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))

        let segments = rawSegments.map { raw in
            TranscriptionResult.Segment(
                text: raw.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                start: raw.start,
                end: raw.end
            )
        }

        // Use the last segment's end time as the overall duration estimate; nil when there are no segments.
        let duration: Double? = segments.last.map { $0.end }

        return TranscriptionResult(text: text, segments: segments, duration: duration)
    }

    /// Collapses any consecutive whitespace (space/tab/newline) in a string into a single space. Leading/trailing whitespace should already be removed before calling.
    static func collapseWhitespace(_ string: String) -> String {
        string
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
