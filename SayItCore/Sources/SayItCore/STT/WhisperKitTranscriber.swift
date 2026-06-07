import Foundation
import WhisperKit

// 说明：WhisperKit 自身也定义了一个名为 `TranscriptionResult` 的类，与本模块
// （SayItCore）的同名结构体冲突；而本模块内还存在一个枚举 `SayItCore`（占位命名空间）
// 又屏蔽了模块名，使得既无法用 `WhisperKit.` 也无法用 `SayItCore.` 前缀消歧。
// 因此本文件不直接以名字引用 WhisperKit 的 `TranscriptionResult`：
// 由类型推断接住 `engine.transcribe(...)` 的返回值，映射逻辑在闭包里完成，
// 这样文件内出现的裸 `TranscriptionResult` 始终指本模块的类型。

/// 基于 WhisperKit（Core ML）的本地语音转写实现。
///
/// 离线、隐私优先：模型在运行期首次使用时从 HuggingFace 拉取并缓存到本地，
/// 之后纯本地推理。模型下载属于运行期行为，不在构建/测试阶段发生。
///
/// 典型用法：
/// ```swift
/// let stt = WhisperKitTranscriber(model: "large-v3-turbo")
/// try await stt.preload()                       // 可选：提前下载并加载模型
/// let result = try await stt.transcribe(samples, sampleRate: 16_000, language: "en")
/// ```
///
/// 实现为 `actor`，保证对底层 ``WhisperKit`` 引擎的串行访问，因而是 `Sendable`。
public actor WhisperKitTranscriber: Transcriber {
    /// 期望的输入采样率（Hz）。WhisperKit 要求 16kHz 单声道 PCM。
    public static let requiredSampleRate: Double = 16_000

    /// 模型标识（如 `"large-v3-turbo"`、`"base"`、`"small.en"`）。
    public nonisolated let model: String

    /// 是否在加载阶段预热模型（降低首帧延迟，代价是峰值内存更高、加载更慢）。
    private let prewarm: Bool

    /// 已加载的 WhisperKit 引擎；首次 ``preload()`` 或 ``transcribe(_:sampleRate:language:)`` 时惰性构建。
    private var engine: WhisperKit?

    /// 创建一个本地 WhisperKit 转写器。
    ///
    /// - Parameters:
    ///   - model: 模型标识。缺省 `"large-v3-turbo"`，与 ``AppConfig`` 的默认本地模型一致。
    ///   - prewarm: 是否预热模型以降低首帧延迟。缺省 `false`。
    public init(model: String = "large-v3-turbo", prewarm: Bool = false) {
        self.model = model
        self.prewarm = prewarm
    }

    /// 确保模型已下载并加载就绪。
    ///
    /// 首次调用会触发模型从 HuggingFace 下载（如本地无缓存），随后加载进内存；
    /// 重复调用是幂等的。建议在用户首次录音前的空闲时机调用以降低首帧延迟。
    ///
    /// - Throws: 模型下载/加载失败时抛出 ``STTError/transcriptionFailed(reason:)``
    ///   （``loadedEngine()`` 把底层失败统一映射为该 case，不会抛 `notReady`）。
    public func preload() async throws {
        _ = try await loadedEngine()
    }

    /// 当前模型是否已加载就绪。
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

        let options = DecodingOptions(language: language)
        // 不显式标注返回类型，让推断接住 WhisperKit 的 `[TranscriptionResult]`，
        // 随即在闭包内把每个分段抽取为本模块无关的原始元组，避免命名歧义。
        // `engine.transcribe(...)` 抛的是 WhisperKit 自己的错误类型，永远不是本模块的
        // ``STTError``，因此这里只需一个把任意底层失败统一映射为
        // ``STTError/transcriptionFailed(reason:)`` 的 catch（不再保留命不中的
        // `catch let error as STTError` 死分支）。
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

    // MARK: - 内部

    /// 返回已加载的引擎，必要时惰性构建（含下载+加载）。
    private func loadedEngine() async throws -> WhisperKit {
        if let engine {
            return engine
        }
        // downloadBase 显式取自 ``ModelManager/downloadBase`` 这一单一真相源：
        // 与 ``ModelManager/download(model:)`` 落盘的根目录完全一致，确保「下了就用得上」。
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

    /// 与 WhisperKit 解耦的中间分段表示，便于在不引用 WhisperKit 类型的情况下做纯映射与单测。
    struct RawSegment: Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    /// 把一次转写的拼接文本与原始分段映射为本模块的 ``TranscriptionResult``。
    ///
    /// WhisperKit 可能因分块（chunking）返回多个结果片段，调用方已按顺序拼接文本并展开分段。
    /// 该函数为纯函数，不依赖模型，可独立单测。
    static func mapResult(joinedText: String, segments rawSegments: [RawSegment]) -> TranscriptionResult {
        // 先去首尾空白，再把内部连续空白折叠成单个空格：分块拼接时（` ` 分隔）各段自带的
        // 首尾空格容易拼出双空格，折叠一次可避免最终文本出现 "a  b" 这类伪影。
        let text = Self.collapseWhitespace(joinedText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))

        let segments = rawSegments.map { raw in
            TranscriptionResult.Segment(
                text: raw.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                start: raw.start,
                end: raw.end
            )
        }

        // 以最后一个分段的结束时间作为整体时长估计；无分段时为 nil。
        let duration: Double? = segments.last.map { $0.end }

        return TranscriptionResult(text: text, segments: segments, duration: duration)
    }

    /// 把字符串中任意连续的空白（空格/制表/换行）折叠为单个空格。首尾空白应在调用前已去除。
    static func collapseWhitespace(_ string: String) -> String {
        string
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
