import Foundation
import os
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
    /// `internal` (not `private`) so `@testable` tests can drive/observe the task-identity
    /// cleanup race; it is not part of the public API.
    @ObservationIgnored var downloadTask: Task<Void, Never>?

    /// Monotonic generation token identifying the current ``downloadTask``.
    ///
    /// `Task` is a value type, so it cannot be compared with `===`; instead each launched
    /// task captures the generation it was assigned, and its trailing cleanup clears the
    /// handle only if that generation is still current. This is the task-identity guard
    /// that stops a cancelled older task from nulling out a newer task's handle.
    @ObservationIgnored private var downloadGeneration: UInt64 = 0

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

    /// Diagnostic logger. The user-facing `.failed(reason:)` carries only a clean short message;
    /// the underlying raw error (NSError dump, network/IO cause) is logged here so it stays
    /// recoverable via `log show` without surfacing garbage in the settings UI.
    nonisolated private static let log = Logger(subsystem: "com.liuwentong.SayIt", category: "model")

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

    /// Whether the folder has the three CoreML weight packages required for WhisperKit loading (each in either .mlmodelc / .mlpackage form),
    /// **and** each one is actually complete on disk (not just a directory left behind by an interrupted/cancelled download).
    ///
    /// Consistent with WhisperKit `loadModels`'s checking semantics (it requires all three of MelSpectrogram / AudioEncoder / TextDecoder
    /// to exist). Reuses `ModelUtilities.detectModelURL` here, to avoid hardcoding extension-name rules ourselves.
    ///
    /// ## Why a mere `fileExists` is not enough
    /// `detectModelURL(inFolder:named:)` resolves a compiled package to its `<name>.mlmodelc`
    /// **directory** URL. A cancelled/partial download leaves that directory present while its
    /// inner weight blob (`weights/weight.bin`) is still missing or zero-length — so a plain
    /// `fileExists(atPath: <.mlmodelc dir>)` returns `true` and the model is wrongly reported
    /// "downloaded". Verified on disk: an interrupted `openai_whisper-base` download left
    /// `AudioEncoder.mlmodelc/weights/` as an EMPTY directory (no `weight.bin`) yet the
    /// `.mlmodelc` directory existed. Here each required package must instead pass
    /// ``isCompleteModelPackage(at:)``, which checks the actual leaf payload.
    nonisolated static func hasRequiredModelFiles(in folder: URL) -> Bool {
        let names = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        for name in names {
            let url = ModelUtilities.detectModelURL(inFolder: folder, named: name)
            if !isCompleteModelPackage(at: url) {
                return false
            }
        }
        return true
    }

    /// Whether a single CoreML model package at `url` is fully present on disk (not a partial download).
    ///
    /// `detectModelURL` returns one of two URL shapes; both are validated against their real payload:
    /// - **Compiled `.mlmodelc` directory**: requires a non-empty `coremldata.bin` descriptor; and if a
    ///   `weights/` directory exists (it does for every WhisperKit encoder/decoder/mel package observed on
    ///   disk), its `weight.bin` must exist and be non-empty. A `weights/` directory present but with a
    ///   missing/zero-length `weight.bin` is exactly the cancelled-download signature, so it fails. A package
    ///   that legitimately ships no `weights/` directory still passes on its descriptor alone (no over-require).
    /// - **`.mlpackage` model file** (`.../model.mlmodel`): requires that leaf file to exist and be non-empty.
    nonisolated static func isCompleteModelPackage(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }

        // `.mlpackage` form: detectModelURL points at the concrete `model.mlmodel` leaf file.
        guard isDir.boolValue else {
            return isNonEmptyFile(at: url)
        }

        // Compiled `.mlmodelc` form: the URL is the package directory. Require its descriptor,
        // and (when present) its weight blob, to be real non-empty files.
        let descriptor = url.appending(component: "coremldata.bin")
        guard isNonEmptyFile(at: descriptor) else { return false }

        let weightsDir = url.appending(component: "weights")
        var weightsIsDir: ObjCBool = false
        if fm.fileExists(atPath: weightsDir.path, isDirectory: &weightsIsDir), weightsIsDir.boolValue {
            // A weights directory exists, so the package is supposed to carry a weight blob.
            // An interrupted download leaves this directory empty / the blob zero-length -> incomplete.
            let weightBlob = weightsDir.appending(component: "weight.bin")
            guard isNonEmptyFile(at: weightBlob) else { return false }
        }
        return true
    }

    /// Whether `url` is an existing regular file with a size greater than zero.
    nonisolated private static func isNonEmptyFile(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return (size ?? 0) > 0
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
        resolveStateFromDisk()
    }

    /// Forcibly re-aligns ``state`` to the actual local cache, **including** when the current
    /// state is `.downloading`.
    ///
    /// This is the cancellation-resolution path. ``refreshState()`` deliberately early-returns
    /// while `.downloading` so a stray refresh can't clobber live progress — but that same guard
    /// would otherwise leave a just-cancelled download stuck at `.downloading` forever (the state
    /// is still `.downloading` at the moment we cancel). Cancellation must instead land on the
    /// real local state: `.notDownloaded` when only a partial cache exists, `.downloaded` only if
    /// the weights happen to be complete. So the cancel paths call this, not ``refreshState()``.
    private func resolveStateFromDisk() {
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

        // Launch the download work behind the shared task-lifecycle wrapper. The wrapper
        // stores the created task into `downloadTask` and clears it on completion ONLY if
        // it is still the current task (see `launchDownloadTask`), so a cancelled older
        // task's trailing cleanup can no longer null out a newer task's handle.
        let task = launchDownloadTask { [weak self] in
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
            } catch {
                // Cancellation is NOT a failure. The authoritative signal is `Task.isCancelled`:
                // `cancelDownload()` calls `downloadTask?.cancel()`, which sets the cancellation flag
                // on THIS very task (the one running this closure), so the flag is observable here no
                // matter which layer threw. That matters because the thrown error's shape is NOT
                // reliable: WhisperKit's Hub layer (`HubApi.httpGet`) catches the underlying
                // `URLError(.cancelled)` in a generic `catch` and re-throws it type-erased as
                // `Hub.HubClientError.downloadError("已取消")` (an internal enum we can't name), while the
                // file-transfer layer instead surfaces a real `URLError(.cancelled)`. We therefore key
                // off the task flag first, and fall back to `isCancellation(error)` to also catch a
                // cancellation that arrived without our task being flagged. On cancel, fall back to the
                // local actual state (`.notDownloaded` when partial); on a genuine failure, show a clean
                // short message and log the raw cause for diagnostics (never store the NSError dump).
                let cancelled = Task.isCancelled || Self.isCancellation(error)
                if !cancelled {
                    Self.log.error("Model download failed for \(newModel, privacy: .public): \(error, privacy: .public)")
                }
                await MainActor.run { [weak self] in
                    guard let self, self.model == newModel else { return }
                    if cancelled {
                        // Resolve to the REAL local state. Must bypass `refreshState()`'s
                        // `.downloading` guard, since the state is still `.downloading` here; a
                        // partial cache lands on `.notDownloaded`, not a stuck `.downloading`.
                        self.resolveStateFromDisk()
                    } else {
                        self.state = .failed(reason: "下载失败，请重试")
                    }
                }
            }
        }
        await task.value
    }

    /// Whether `error` represents a cancelled download rather than a genuine failure.
    ///
    /// This is the **secondary** classifier; the primary signal at the call site is
    /// `Task.isCancelled` (see the download `catch`). It exists to also catch a cancellation that
    /// surfaced without our task being flagged. A cancel can arrive in several shapes depending on
    /// which WhisperKit layer threw:
    /// - a Swift `CancellationError` (cooperative task cancellation);
    /// - an `NSError`/`URLError` with domain `NSURLErrorDomain` and code `NSURLErrorCancelled`
    ///   (-999), which `URLSession` raises when its in-flight download task is cancelled (this is
    ///   what the file-transfer layer's `Downloader.cancel()` broadcasts);
    /// - a **type-erased** `Hub.HubClientError.downloadError(message)` — WhisperKit's `HubApi.httpGet`
    ///   catches the underlying `URLError(.cancelled)` in a generic `catch` and re-throws it as this
    ///   internal enum, so the original cancellation type is lost. We can't name that internal type,
    ///   so we match the residual cancellation **message** the URLError carries (e.g. localized
    ///   "cancelled" / "已取消").
    /// Treating any of these as a cancellation keeps the UI out of `.failed` (and off the raw NSError
    /// dump) when the user cancels.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        // Defense in depth for the type-erased Hub wrapper: the original cancellation type is gone,
        // but the message is the localized description of `URLError(.cancelled)`. Match on that.
        return messageLooksLikeCancellation(nsError.localizedDescription)
            || messageLooksLikeCancellation((error as? LocalizedError)?.errorDescription ?? "")
    }

    /// Whether a human-readable error message looks like a cancellation rather than a real failure.
    /// Matches the localized description of `URLError(.cancelled)` across locales we ship to
    /// (English "cancelled"/"canceled", Simplified Chinese "已取消"). Kept narrow on purpose so an
    /// unrelated message can't be misread as a cancel.
    nonisolated static func messageLooksLikeCancellation(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("cancelled")
            || lowered.contains("canceled")
            || message.contains("已取消")
    }

    /// Wraps `operation` in a `Task`, stores it as the current ``downloadTask``, and on
    /// completion clears ``downloadTask`` **only if it is still the current task**.
    ///
    /// ## Why the task-identity guard
    /// `download(model:)` can run a cancel+restart sequence: a cancelled older `taskA`
    /// may not finish its trailing cleanup until AFTER a newer `taskB` has already been
    /// created and stored. If the cleanup unconditionally ran `downloadTask = nil`, it
    /// would null out `taskB`'s handle, and a subsequent ``cancelDownload()`` — which
    /// reads ``downloadTask`` to cancel it — would see `nil` and silently do nothing,
    /// turning the cancel button into a no-op. `Task` is a value type and cannot be
    /// compared with `===`, so each task captures the ``downloadGeneration`` it was
    /// assigned and only clears the handle when that generation is still current. This
    /// stops an outgoing task from clobbering its successor.
    ///
    /// - Parameter operation: the actual download work; runs inside the returned task.
    /// - Returns: the created task, so the caller can `await` it.
    ///
    /// `internal` (not `private`) so `@testable` tests can reproduce the cancel+restart
    /// cleanup race directly; it is not part of the public API.
    func launchDownloadTask(
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        downloadGeneration &+= 1
        let myGeneration = downloadGeneration
        let createdTask = Task { [weak self] in
            await operation()
            await MainActor.run { [weak self] in
                // Only clear the handle if this is still the current task; a newer task
                // (started after a cancel+restart) must not be clobbered by this one.
                guard let self, self.downloadGeneration == myGeneration else { return }
                self.downloadTask = nil
            }
        }
        downloadTask = createdTask
        return createdTask
    }

    /// Cancels the in-progress download (if any). The state falls back to the local actual state.
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = state {
            // The state is `.downloading` right now, so `refreshState()` would early-return and
            // leave it stuck there. Resolve straight from the local cache instead: a partial
            // download becomes `.notDownloaded`, never a phantom `.downloading`/`.failed`.
            resolveStateFromDisk()
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
