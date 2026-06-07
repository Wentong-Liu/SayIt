import Foundation
import WhisperKit

/// 本地 WhisperKit 模型的下载 / 状态管理器。
///
/// 负责三件事：
/// 1. **检测**指定模型是否已在本地缓存（关键权重文件齐全）；
/// 2. **下载**模型到 ``WhisperKitTranscriber`` 实际加载所用的同一目录（见下方一致性说明）；
/// 3. 以 `@MainActor @Observable` 的 ``state`` 属性实时把下载进度/结果暴露给 UI。
///
/// ## 下载目录一致性（关键正确性点）
/// WhisperKit 下载与加载都以一个 `downloadBase` 为根：
/// 缓存布局为 `downloadBase/models/<repo>/<variantFolder>/`，其中 repo 为
/// `argmaxinc/whisperkit-coreml`，`variantFolder` 是诸如 `openai_whisper-large-v3_turbo`
/// 这类仓库内文件夹名（`models/<repo>` 这层由 `HubApi.localRepoLocation` 自动拼接，
/// 仅取决于 `downloadBase` 这一根）。
///
/// WhisperKit 的**默认** `downloadBase` 是 `~/Documents/huggingface`（见 `HubApi.init`），
/// 但 `~/Documents` 受 macOS TCC 保护：本 App 为已签名、启用 hardened-runtime 且**非沙盒**，
/// 无法在该目录创建/写入，导致目录从未被建立、本地模型下载必然失败。
/// 因此本类型把根目录改为不受 TCC 限制的 `Application Support/SayIt/models`，
/// 并在首次访问时创建（缺失则建），从而修复下载失败问题。
///
/// 为保证「下了就用得上」，本类型把该 `downloadBase` 抽成**单一真相源** ``Self/downloadBase``：
/// - ``download(model:)`` 把它显式传给 `WhisperKit.download(variant:downloadBase:)`；
/// - ``WhisperKitTranscriber`` 构造 `WhisperKitConfig` 时也把同一个 ``ModelManager/downloadBase``
///   传给 `downloadBase` 字段。
///
/// 二者引用同一常量，因此下载落盘目录与加载读取目录必然一致。
@MainActor
@Observable
public final class ModelManager {
    /// 当前模型的下载/缓存状态。
    public enum State: Equatable, Sendable {
        /// 本地无缓存（或文件不齐全），需要下载。
        case notDownloaded
        /// 下载中，`progress` 为 0...1 的完成比例。
        case downloading(progress: Double)
        /// 已下载且关键权重文件齐全，可直接加载。
        case downloaded
        /// 下载失败，附带可读原因。
        case failed(reason: String)
    }

    /// UI 观察的实时状态。仅在主线程读写（`@MainActor`）。
    public private(set) var state: State = .notDownloaded

    /// 当前关注的模型友好名（如 `"large-v3-turbo"`）。
    public private(set) var model: String

    /// 进行中的下载任务；用于取消与防重入。
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    /// - Parameter model: 初始关注的模型友好名；默认 `"large-v3-turbo"`，与 ``AppConfig/localModel``
    ///   的缺省、``WhisperKitTranscriber`` 的缺省一致。
    public init(model: String = "large-v3-turbo") {
        self.model = model
        self.state = Self.isDownloaded(model: model) ? .downloaded : .notDownloaded
    }

    // MARK: - 下载根目录（单一真相源）

    /// WhisperKit 模型缓存根目录：`Application Support/SayIt/models`。
    ///
    /// 不使用 WhisperKit 默认的 `~/Documents/huggingface`：`~/Documents` 受 macOS TCC 保护，
    /// 已签名 hardened-runtime 非沙盒 App 无法在其下创建/写入，会导致本地模型下载失败。
    /// 改用不受 TCC 限制的 Application Support，并在此处确保目录存在（缺失则创建）。
    ///
    /// `WhisperKitTranscriber` 与 ``download(model:)`` 都引用此常量作为 `downloadBase`，
    /// 从而保证下载落盘与加载读取指向同一处。
    nonisolated public static let downloadBase: URL = {
        let fm = FileManager.default
        let base: URL
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            base = appSupport
                .appending(component: "SayIt")
                .appending(component: "models")
        } else {
            // 极端情况下取不到 Application Support：回退到缓存目录，仍避开受 TCC 保护的 Documents。
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            base = caches
                .appending(component: "SayIt")
                .appending(component: "models")
        }
        // 确保根目录存在，使 WhisperKit/HubApi 能直接在其下写入缓存。
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// WhisperKit 官方模型仓库 id。
    nonisolated public static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// 缓存中该 repo 的本地根目录：`downloadBase/models/argmaxinc/whisperkit-coreml`。
    /// 与 `HubApi.localRepoLocation` 的布局（`downloadBase/<repoType>/<repoId>`）一致。
    nonisolated static var repoCacheDirectory: URL {
        downloadBase
            .appending(component: "models")
            .appending(component: modelRepo)
    }

    // MARK: - 友好名 → WhisperKit variant 映射

    /// 把 ``AppConfig`` 的友好模型名映射到传给 WhisperKit 的 variant 标识。
    ///
    /// 当前 sayit 暴露的本地模型名（large-v3-turbo / large-v3 / medium / small / base）即
    /// WhisperKit `download(variant:)` 接受的 variant 串，映射为恒等；集中于此便于将来调整，
    /// 且让路径匹配（``cachedModelFolder(for:)``）有单一入口。
    nonisolated public static func variant(for model: String) -> String {
        model
    }

    // MARK: - 已下载检测

    /// 指定模型是否已在本地缓存且关键权重文件齐全。
    ///
    /// 不发起任何网络请求：扫描 ``repoCacheDirectory`` 下与该 variant 匹配的文件夹，
    /// 检查三个关键 CoreML 权重（MelSpectrogram / AudioEncoder / TextDecoder）是否齐全。
    nonisolated public static func isDownloaded(model: String) -> Bool {
        cachedModelFolder(for: model) != nil
    }

    /// 返回本地已缓存且权重齐全的该模型文件夹（无则 nil）。生产路径使用 ``repoCacheDirectory``。
    nonisolated static func cachedModelFolder(for model: String) -> URL? {
        cachedModelFolder(for: model, in: repoCacheDirectory)
    }

    /// 在指定 repo 根目录下查找本地已缓存且权重齐全的该模型文件夹（无则 nil）。
    ///
    /// WhisperKit 仓库内文件夹名形如 `openai_whisper-large-v3_turbo`，与友好名（`large-v3-turbo`）
    /// 在连字符/下划线上可能不同，故按「归一化后包含」匹配：把 `-`/`_` 都去掉再比较。
    /// `repoDir` 参数仅为单测注入临时目录；生产由上面的便捷重载传入 ``repoCacheDirectory``。
    nonisolated static func cachedModelFolder(for model: String, in repoDir: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: repoDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let needle = normalizedVariantKey(variant(for: model))

        // 在直接命中与归一化包含命中之间，优先取权重齐全者。
        for folder in entries {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let folderKey = normalizedVariantKey(folder.lastPathComponent)
            guard folderKey.contains(needle) else { continue }
            if hasRequiredModelFiles(in: folder) {
                return folder
            }
        }
        return nil
    }

    /// 把 variant / 文件夹名归一化为仅含小写字母数字的键，消除 `-`/`_`/大小写差异。
    nonisolated static func normalizedVariantKey(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 文件夹内是否齐备 WhisperKit 加载所必需的三个 CoreML 权重包（任一 .mlmodelc / .mlpackage 形式）。
    ///
    /// 与 WhisperKit `loadModels` 的检查口径一致（它要求 MelSpectrogram / AudioEncoder / TextDecoder
    /// 三者都存在）。这里复用 `ModelUtilities.detectModelURL`，避免自行硬编码扩展名规则。
    nonisolated static func hasRequiredModelFiles(in folder: URL) -> Bool {
        let names = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let fm = FileManager.default
        for name in names {
            let url = ModelUtilities.detectModelURL(inFolder: folder, named: name)
            if !fm.fileExists(atPath: url.path) {
                return false
            }
        }
        return true
    }

    // MARK: - 状态刷新 / 切换模型

    /// 把 ``state`` 重新对齐到当前 ``model`` 的本地缓存实况（不下载、不联网）。
    /// 进入设置页或下载结束后调用。下载进行中则保持不变（避免覆盖进度）。
    public func refreshState() {
        if case .downloading = state { return }
        state = Self.isDownloaded(model: model) ? .downloaded : .notDownloaded
    }

    /// 切换到另一模型并据本地缓存刷新状态；若正在下载旧模型则先取消。
    public func setModel(_ newModel: String) {
        guard newModel != model else {
            refreshState()
            return
        }
        cancelDownload()
        model = newModel
        state = Self.isDownloaded(model: newModel) ? .downloaded : .notDownloaded
    }

    // MARK: - 下载

    /// 下载当前 ``model`` 到 ``downloadBase``，期间实时更新 ``state``。
    ///
    /// 幂等保护：正在下载则直接返回；非 `force` 且已下载也直接返回。下载完成校验关键权重齐全后
    /// 置 `.downloaded`，失败置 `.failed`。被取消则回落到本地实况状态。
    ///
    /// - Parameter force: 为 `true` 时即便本地已缓存也重新下载（「重新下载/重试」按钮用）。
    public func download(force: Bool = false) async {
        await download(model: model, force: force)
    }

    /// 下载指定模型（会把 ``model`` 切到该模型）。
    /// - Parameter force: 为 `true` 时即便本地已缓存也重新下载。
    public func download(model newModel: String, force: Bool = false) async {
        if newModel != model {
            setModel(newModel)
        }
        // 正在下载必不重复触发；非强制且已缓存则跳过。
        switch state {
        case .downloading:
            return
        case .downloaded where !force && Self.isDownloaded(model: newModel):
            return
        default:
            break
        }

        state = .downloading(progress: 0)

        let variant = Self.variant(for: newModel)
        let base = Self.downloadBase
        let repo = Self.modelRepo

        let task = Task { [weak self] in
            // 弱引用提前固定到 @Sendable 进度回调可捕获的局部常量，避免回调强引用 self。
            let weakSelf = WeakBox(self)
            do {
                // 进度回调可能在任意线程触发：抽出比例后切回主线程更新 state。
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: base,
                    from: repo,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            weakSelf.value?.applyProgress(fraction, forModel: newModel)
                        }
                    }
                )
                await MainActor.run { [weak self] in
                    guard let self, self.model == newModel else { return }
                    // 以本地权重实况为准做最终判定，避免「下载返回成功但文件不齐」误报。
                    self.state = Self.isDownloaded(model: newModel) ? .downloaded : .failed(reason: "下载完成但模型文件不完整")
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.model == newModel else { return }
                    self.refreshState()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.model == newModel else { return }
                    self.state = .failed(reason: String(describing: error))
                }
            }
            await MainActor.run { [weak self] in
                self?.downloadTask = nil
            }
        }
        downloadTask = task
        await task.value
    }

    /// 取消进行中的下载（若有）。状态回落到本地实况。
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = state {
            refreshState()
        }
    }

    /// 主线程内把下载比例写入 ``state``（仅当仍在下载且模型未被切换）。
    private func applyProgress(_ fraction: Double, forModel: String) {
        guard model == forModel else { return }
        guard case .downloading = state else { return }
        let clamped = min(max(fraction, 0), 1)
        state = .downloading(progress: clamped)
    }
}

/// 对 ``ModelManager`` 的弱引用盒子，使其可被 `@Sendable` 进度回调捕获。
///
/// `ModelManager` 是 `@MainActor` 隔离类型，弱引用本身非 `Sendable`；本盒子标注
/// `@unchecked Sendable`，并约束**只在主线程**通过 ``value`` 解引用（回调里始终
/// 在 `Task { @MainActor in ... }` 内访问），从而不破坏隔离保证。
private final class WeakBox: @unchecked Sendable {
    weak var value: ModelManager?
    init(_ value: ModelManager?) { self.value = value }
}
