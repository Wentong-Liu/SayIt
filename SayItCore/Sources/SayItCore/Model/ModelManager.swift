import Foundation
import WhisperKit

/// Download / state manager for the local WhisperKit model.
///
/// Responsible for three things:
/// 1. **Detect** whether the specified model is already cached locally (key weight files complete);
/// 2. **Download** the model into the same directory ``WhisperKitTranscriber`` actually loads from (see the consistency note below);
/// 3. Expose download progress/result to the UI in real time via the `@MainActor @Observable` ``state`` property.
///
/// ## Download directory consistency (a key correctness point)
/// WhisperKit downloads and loads both rooted at one `downloadBase`:
/// the cache layout is `downloadBase/models/<repo>/<variantFolder>/`, where repo is
/// `argmaxinc/whisperkit-coreml`, and `variantFolder` is the **real** in-repo folder name such as `openai_whisper-large-v3-v20240930_turbo`
/// (the `models/<repo>` layer is auto-assembled by `HubApi.localRepoLocation`,
/// depending only on the single root `downloadBase`).
///
/// WhisperKit's **default** `downloadBase` is `~/Documents/huggingface` (see `HubApi.init`),
/// but `~/Documents` is protected by macOS TCC: this App is signed, has hardened-runtime enabled, and is **non-sandboxed**,
/// so it cannot create/write in that directory, leaving the directory never created and the local model download bound to fail.
/// Therefore this type changes the root to the TCC-unrestricted `Application Support/SayIt/models`,
/// creating it on first access (created if missing), thereby fixing the download failure.
///
/// To guarantee "downloaded means usable", this type extracts that `downloadBase` into a **single source of truth** ``Self/downloadBase``:
/// - ``download(model:)`` passes it explicitly to `WhisperKit.download(variant:downloadBase:)`;
/// - ``WhisperKitTranscriber`` also passes the same ``ModelManager/downloadBase`` when constructing `WhisperKitConfig`
///   to the `downloadBase` field.
///
/// Both reference the same constant, so the download destination directory and the load directory are necessarily identical.
@MainActor
@Observable
public final class ModelManager {
    /// The download/cache state of the current model.
    public enum State: Equatable, Sendable {
        /// No local cache (or files incomplete), needs downloading.
        case notDownloaded
        /// Downloading.
        /// - `progress`: completion fraction in `0...1`.
        /// - `speedBytesPerSec`: smoothed download speed in bytes/sec, `nil` until the
        ///   first measurable sample (so the UI shows only the percentage at the very
        ///   start, then percentage + speed). `Double?` stays `Equatable` & `Sendable`.
        case downloading(progress: Double, speedBytesPerSec: Double?)
        /// Downloaded with key weight files complete, can be loaded directly.
        case downloaded
        /// Download failed, with a human-readable reason attached.
        case failed(reason: String)
    }

    /// The real-time state observed by the UI. Read/written only on the main thread (`@MainActor`).
    public private(set) var state: State = .notDownloaded

    /// The friendly name of the currently tracked model (e.g. `"large-v3-turbo"`).
    public private(set) var model: String

    /// The in-progress download task; used for cancellation and re-entrancy prevention.
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    // MARK: - Download-speed tracking (MainActor-isolated)
    //
    // The Progress forwarded by WhisperKit's progressCallback has FILE-COUNT units
    // (HubApi adds one unit per file), not bytes, so a byte delta from completedUnitCount
    // would be wrong. The only continuous byte-like signal is `fractionCompleted` (0...1),
    // so we scale it by an estimated total size and differentiate over wall-clock time.
    // These fields are only ever touched from `applyProgress`, which runs on the MainActor.

    /// Wall-clock timestamp of the last progress sample used for the speed estimate.
    @ObservationIgnored private var lastSampleTime: Date?
    /// `fractionCompleted * estimatedDownloadBytes` captured at the last sample.
    @ObservationIgnored private var lastFractionBytes: Double?
    /// Exponential moving average of bytes/sec; `nil` until the first measurable sample.
    @ObservationIgnored private var smoothedBytesPerSec: Double?

    /// - Parameter model: the initially tracked model friendly name; defaults to `"large-v3-turbo"`, consistent with ``AppConfig/localModel``'s
    ///   default and ``WhisperKitTranscriber``'s default.
    public init(model: String = "large-v3-turbo") {
        self.model = model
        self.state = Self.isDownloaded(model: model) ? .downloaded : .notDownloaded
    }

    // MARK: - Download root directory (single source of truth)

    /// The WhisperKit model cache root directory: `Application Support/SayIt/models`.
    ///
    /// Does not use WhisperKit's default `~/Documents/huggingface`: `~/Documents` is protected by macOS TCC,
    /// a signed hardened-runtime non-sandboxed App cannot create/write under it, which would cause local model download failure.
    /// Uses the TCC-unrestricted Application Support instead, and ensures the directory exists here (created if missing).
    ///
    /// Both `WhisperKitTranscriber` and ``download(model:)`` reference this constant as `downloadBase`,
    /// thereby guaranteeing the download destination and the load source point to the same place.
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
            // In the extreme case Application Support cannot be obtained: fall back to the always-available, always-writable temporary directory, still avoiding the TCC-protected Documents.
            base = FileManager.default.temporaryDirectory
                .appending(component: "SayIt")
                .appending(component: "models")
        }
        // Ensure the root directory exists, so WhisperKit/HubApi can write the cache directly under it.
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// The official WhisperKit model repository id.
    nonisolated public static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// The local root directory of this repo in the cache: `downloadBase/models/argmaxinc/whisperkit-coreml`.
    /// Consistent with `HubApi.localRepoLocation`'s layout (`downloadBase/<repoType>/<repoId>`).
    nonisolated static var repoCacheDirectory: URL {
        downloadBase
            .appending(component: "models")
            .appending(component: modelRepo)
    }

    // MARK: - Friendly name -> WhisperKit variant mapping

    /// Maps ``AppConfig``'s friendly model name to the **real repository folder name** (variant) passed to WhisperKit.
    ///
    /// Key correctness point: `WhisperKit.download(variant:)` / `WhisperKitConfig(model:)` accept the
    /// **real folder name** inside the `argmaxinc/whisperkit-coreml` repo (like `openai_whisper-large-v3-v20240930_turbo`),
    /// not the friendly name exposed by the sayit UI (`large-v3-turbo`). Earlier the friendly name was passed as the variant directly, and WhisperKit
    /// could not resolve a real folder -> the directory was created but always empty, a "silent download failure". Here the friendly name is explicitly mapped to
    /// a real folder name verified to exist via HuggingFace (HTTP 200); unknown names fall back to the existing convention of adding the `openai_whisper-` prefix.
    ///
    /// Centralized here for easy future adjustment, and so path matching (``cachedModelFolder(for:)``) and download/load share a single entry point.
    nonisolated public static func variant(for model: String) -> String {
        switch model {
        case "large-v3-turbo": return "openai_whisper-large-v3-v20240930_turbo"
        case "large-v3":       return "openai_whisper-large-v3"
        case "medium":         return "openai_whisper-medium"
        case "small":          return "openai_whisper-small"
        case "base":           return "openai_whisper-base"
        case "tiny":           return "openai_whisper-tiny"
        default:
            // If it is already a real repository folder name (with the `openai_whisper-` prefix), return it as-is;
            // otherwise fall back to adding the prefix per the repository naming convention.
            return model.hasPrefix("openai_whisper-") ? model : "openai_whisper-\(model)"
        }
    }

    // MARK: - Downloaded detection

    /// Whether the specified model is already cached locally with key weight files complete.
    ///
    /// Issues no network requests: scans for folders under ``repoCacheDirectory`` matching this variant,
    /// checking whether the three key CoreML weights (MelSpectrogram / AudioEncoder / TextDecoder) are complete.
    nonisolated public static func isDownloaded(model: String) -> Bool {
        cachedModelFolder(for: model) != nil
    }

    /// Returns the locally-cached, weight-complete folder for this model (nil if none). The production path uses ``repoCacheDirectory``.
    nonisolated static func cachedModelFolder(for model: String) -> URL? {
        cachedModelFolder(for: model, in: repoCacheDirectory)
    }

    /// Looks for the locally-cached, weight-complete folder for this model under the specified repo root directory (nil if none).
    ///
    /// ``variant(for:)`` now returns the **real** folder name used by WhisperKit downloads
    /// (e.g. `openai_whisper-large-v3-v20240930_turbo`), i.e. the cache folder name should correspond one-to-one with the variant,
    /// so it matches by normalized **equality** (eliminating `-`/`_`/case differences), not "contains" -- avoiding `large-v3`'s
    /// normalized key being wrongly hit by the turbo folder name prefix. The `repoDir` parameter is only for unit tests to inject a temp directory;
    /// production passes ``repoCacheDirectory`` via the convenience overload above.
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

        for folder in entries {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let folderKey = normalizedVariantKey(folder.lastPathComponent)
            guard folderKey == needle else { continue }
            if hasRequiredModelFiles(in: folder) {
                return folder
            }
        }
        return nil
    }

    /// Normalizes a variant / folder name into a key containing only lowercase alphanumerics, eliminating `-`/`_`/case differences.
    nonisolated static func normalizedVariantKey(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Whether the folder has the three CoreML weight packages required for WhisperKit loading (each in either .mlmodelc / .mlpackage form).
    ///
    /// Consistent with WhisperKit `loadModels`'s checking semantics (it requires all three of MelSpectrogram / AudioEncoder / TextDecoder
    /// to exist). Reuses `ModelUtilities.detectModelURL` here, to avoid hardcoding extension-name rules ourselves.
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

    // MARK: - Download-speed estimation helpers

    /// Approximate on-disk download size, in bytes, for a friendly/variant model name.
    ///
    /// These are deliberately rough constants. The Progress reported by WhisperKit /
    /// HubApi counts FILES, not bytes (one progress unit per file in the repo), so the
    /// only continuous signal we get is `fractionCompleted` (0...1). We multiply that
    /// fraction by this estimate purely to turn it into a human-facing speed readout
    /// (e.g. "1.2 MB/s"); exact accuracy is non-critical for a live indicator.
    /// Unknown names fall back to a generic ~1 GB so the speed number is still sane.
    nonisolated public static func estimatedDownloadBytes(for model: String) -> Double {
        // Normalize so both friendly names ("tiny") and real folder names
        // ("openai_whisper-tiny") map to the same bucket.
        let key = normalizedVariantKey(variant(for: model))
        let mb = 1_000_000.0
        let gb = 1_000_000_000.0
        // Match against the normalized real-folder keys produced by `variant(for:)`.
        if key.contains("largev3v20240930turbo") { return 1.6 * gb }  // large-v3-turbo
        if key.contains("largev3")              { return 3.1 * gb }   // large-v3
        if key.contains("medium")               { return 1.5 * gb }
        if key.contains("small")                { return 480 * mb }
        if key.contains("base")                 { return 145 * mb }
        if key.contains("tiny")                 { return 75 * mb }
        return 1.0 * gb  // generic fallback for unknown models
    }

    /// Pure exponential-moving-average step for the speed estimate (no I/O, deterministic).
    ///
    /// Extracted as a `nonisolated static` helper so the smoothing math is unit-testable
    /// without any network, matching this file's "pure logic, no real network" tests.
    /// - Parameters:
    ///   - previous: prior smoothed bytes/sec, or `nil` if this is the first sample.
    ///   - deltaBytes: estimated bytes transferred since the last sample (clamped to >= 0).
    ///   - dt: elapsed wall-clock seconds since the last sample (must be > 0).
    ///   - alpha: EMA weight for the new instantaneous reading (0...1); ~0.3 is a light smooth.
    /// - Returns: the new smoothed bytes/sec.
    nonisolated static func smoothedSpeed(
        previous: Double?,
        deltaBytes: Double,
        dt: Double,
        alpha: Double = 0.3
    ) -> Double {
        let instantaneous = max(0, deltaBytes) / max(dt, .ulpOfOne)
        guard let previous else { return instantaneous }
        return alpha * instantaneous + (1 - alpha) * previous
    }

    /// Reset the speed-tracking state to its pre-download baseline.
    private func resetSpeedTracking() {
        lastSampleTime = nil
        lastFractionBytes = nil
        smoothedBytesPerSec = nil
    }

    // MARK: - State refresh / switch model

    /// Re-aligns ``state`` to the current ``model``'s actual local cache (no download, no network).
    /// Called on entering the settings page or after a download finishes. If a download is in progress it stays unchanged (avoiding overwriting progress).
    public func refreshState() {
        if case .downloading = state { return }
        state = Self.isDownloaded(model: model) ? .downloaded : .notDownloaded
    }

    /// Switches to another model and refreshes state per the local cache; if the old model is downloading it is cancelled first.
    public func setModel(_ newModel: String) {
        guard newModel != model else {
            refreshState()
            return
        }
        cancelDownload()
        model = newModel
        state = Self.isDownloaded(model: newModel) ? .downloaded : .notDownloaded
    }

    // MARK: - Download

    /// Downloads the current ``model`` into ``downloadBase``, updating ``state`` in real time during the process.
    ///
    /// Idempotency protection: returns directly if downloading; also returns directly if not `force` and already downloaded. After download completes, validates key weights are complete then
    /// sets `.downloaded`, sets `.failed` on failure. If cancelled, falls back to the local actual state.
    ///
    /// - Parameter force: when `true`, re-download even if already cached locally (for the "re-download/retry" button).
    public func download(force: Bool = false) async {
        await download(model: model, force: force)
    }

    /// Downloads the specified model (switches ``model`` to this model).
    /// - Parameter force: when `true`, re-download even if already cached locally.
    public func download(model newModel: String, force: Bool = false) async {
        if newModel != model {
            setModel(newModel)
        }
        // A download in progress is never triggered twice; if not forced and already cached, skip.
        switch state {
        case .downloading:
            return
        case .downloaded where !force && Self.isDownloaded(model: newModel):
            return
        default:
            break
        }

        // Reset the speed tracker so a new download starts from a clean baseline.
        resetSpeedTracking()
        state = .downloading(progress: 0, speedBytesPerSec: nil)

        let variant = Self.variant(for: newModel)
        let base = Self.downloadBase
        let repo = Self.modelRepo

        let task = Task { [weak self] in
            // Pin the weak reference ahead into a local constant capturable by the @Sendable progress callback, to avoid the callback strongly referencing self.
            let weakSelf = WeakBox(self)
            do {
                // The progress callback may fire on any thread: extract the ratio then switch back to the main thread to update state.
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
                    // Make the final decision based on the local weights' actual state, avoiding a "download returned success but files incomplete" false positive.
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

    /// Cancels the in-progress download (if any). The state falls back to the local actual state.
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = state {
            refreshState()
        }
    }

    /// Writes the download ratio into ``state`` on the main thread (only when still downloading and the model has not been switched).
    ///
    /// Also derives a smoothed download speed: the Progress units are file counts (not
    /// bytes), so we scale `fractionCompleted` by an estimated total size and
    /// differentiate that estimated-byte position over wall-clock time. The first sample
    /// only seeds the baseline (speed stays `nil`); subsequent samples produce a value.
    private func applyProgress(_ fraction: Double, forModel: String) {
        guard model == forModel else { return }
        guard case .downloading = state else { return }
        let clamped = min(max(fraction, 0), 1)

        let now = Date()
        let currentBytes = clamped * Self.estimatedDownloadBytes(for: forModel)
        if let lastTime = lastSampleTime, let lastBytes = lastFractionBytes {
            let dt = now.timeIntervalSince(lastTime)
            // Ignore samples that are too close together to differentiate reliably.
            if dt > 0.05 {
                smoothedBytesPerSec = Self.smoothedSpeed(
                    previous: smoothedBytesPerSec,
                    deltaBytes: currentBytes - lastBytes,
                    dt: dt
                )
                lastSampleTime = now
                lastFractionBytes = currentBytes
            }
        } else {
            // First sample: seed the baseline, leave speed nil until we can measure a delta.
            lastSampleTime = now
            lastFractionBytes = currentBytes
        }

        state = .downloading(progress: clamped, speedBytesPerSec: smoothedBytesPerSec)
    }
}

/// A weak-reference box for ``ModelManager``, making it capturable by `@Sendable` progress callbacks.
///
/// `ModelManager` is a `@MainActor`-isolated type, and a weak reference itself is not `Sendable`; this box is annotated
/// `@unchecked Sendable` and constrains dereferencing via ``value`` to **the main thread only** (callbacks always
/// access it inside `Task { @MainActor in ... }`), thereby not breaking the isolation guarantee.
private final class WeakBox: @unchecked Sendable {
    weak var value: ModelManager?
    init(_ value: ModelManager?) { self.value = value }
}
