import Foundation
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

    /// The model identifier (e.g. `"large-v3-turbo"`, `"base"`, `"small.en"`).
    public nonisolated let model: String

    /// Whether to prewarm the model during loading (reduces first-frame latency, at the cost of higher peak memory and slower loading).
    private let prewarm: Bool

    /// The loaded WhisperKit engine; lazily built on the first ``preload()`` or ``transcribe(_:sampleRate:language:)``.
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
        language: String?
    ) async throws -> TranscriptionResult {
        guard !audio.isEmpty else {
            throw STTError.emptyAudio
        }
        guard sampleRate == Self.requiredSampleRate else {
            throw STTError.unsupportedFormat
        }

        let engine = try await loadedEngine()

        let options = Self.makeDecodingOptions(language: language)
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
    static func makeDecodingOptions(language: String?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil
        )
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
