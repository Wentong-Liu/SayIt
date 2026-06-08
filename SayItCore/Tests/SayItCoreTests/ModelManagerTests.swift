import XCTest
@testable import SayItCore

/// ModelManager pure-logic unit test: variant mapping, cache path layout, normalized matching, weight detection and the state machine.
/// **Does not trigger a real network download** (that would require fetching multi-GB models online, left for on-device integration verification).
final class ModelManagerTests: XCTestCase {

    // MARK: - Friendly name -> real repository variant folder name mapping

    func testVariantMappingResolvesToRealRepoFolderNames() {
        // The friendly name must map to a folder name that really exists in the argmaxinc/whisperkit-coreml repo
        // (verified via HuggingFace HTTP 200), otherwise WhisperKit.download cannot resolve it and the download silently fails.
        XCTAssertEqual(ModelManager.variant(for: "large-v3-turbo"), "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(ModelManager.variant(for: "large-v3"), "openai_whisper-large-v3")
        XCTAssertEqual(ModelManager.variant(for: "medium"), "openai_whisper-medium")
        XCTAssertEqual(ModelManager.variant(for: "small"), "openai_whisper-small")
        XCTAssertEqual(ModelManager.variant(for: "base"), "openai_whisper-base")
        XCTAssertEqual(ModelManager.variant(for: "tiny"), "openai_whisper-tiny")
    }

    func testVariantMappingPassesThroughRealFolderName() {
        // What is already a real repository folder name (with the openai_whisper- prefix) should be returned as-is, not prefixed again.
        XCTAssertEqual(
            ModelManager.variant(for: "openai_whisper-large-v3-v20240930_turbo"),
            "openai_whisper-large-v3-v20240930_turbo"
        )
    }

    func testVariantMappingFallsBackToPrefixedNameForUnknownModel() {
        // An unknown friendly name falls back to adding the prefix per the repository naming convention.
        XCTAssertEqual(ModelManager.variant(for: "distil-large-v3"), "openai_whisper-distil-large-v3")
    }

    // MARK: - Download root directory / cache layout (single source of truth)

    func testDownloadBaseIsApplicationSupportSayItModels() {
        // ~/Documents is protected by TCC, a signed hardened-runtime non-sandboxed App cannot write into it;
        // so the root directory uses the unrestricted Application Support/SayIt/models.
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let expected = appSupport!
            .appending(component: "SayIt")
            .appending(component: "models")
        XCTAssertEqual(ModelManager.downloadBase, expected,
                       "downloadBase must be under Application Support/SayIt/models (avoiding TCC-protected Documents)")
    }

    func testDownloadBaseDirectoryExists() {
        // Accessing downloadBase should have ensured the directory exists, so WhisperKit/HubApi can write directly.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: ModelManager.downloadBase.path, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue,
                      "the downloadBase directory should exist after first access")
    }

    func testRepoCacheDirectoryLayoutMatchesHubApi() {
        // HubApi.localRepoLocation layout: downloadBase/<repoType=="models">/<repoId>
        let expected = ModelManager.downloadBase
            .appending(component: "models")
            .appending(component: "argmaxinc/whisperkit-coreml")
        XCTAssertEqual(ModelManager.repoCacheDirectory, expected)
    }

    func testModelRepoIsArgmaxWhisperKitCoreML() {
        XCTAssertEqual(ModelManager.modelRepo, "argmaxinc/whisperkit-coreml")
    }

    // MARK: - Normalized matching (eliminating - / _ / case differences)

    func testNormalizedVariantKeyStripsSeparatorsAndCase() {
        XCTAssertEqual(ModelManager.normalizedVariantKey("large-v3-turbo"), "largev3turbo")
        XCTAssertEqual(ModelManager.normalizedVariantKey("openai_whisper-large-v3-v20240930_turbo"),
                       "openaiwhisperlargev3v20240930turbo")
    }

    func testNormalizedFolderNameEqualsNormalizedVariant() {
        // A real repository folder name, after normalization, should be **equal** to the normalized variant (the download lands with this name).
        let folderKey = ModelManager.normalizedVariantKey("openai_whisper-large-v3-v20240930_turbo")
        let variantKey = ModelManager.normalizedVariantKey(ModelManager.variant(for: "large-v3-turbo"))
        XCTAssertEqual(folderKey, variantKey,
                       "after normalization the repo folder name should equal the normalized variant")
    }

    // MARK: - Weight detection (constructing a fake cache with a temp directory)

    func testHasRequiredModelFilesTrueWhenAllThreePresent() throws {
        let folder = try makeTempModelFolder(present: ["MelSpectrogram", "AudioEncoder", "TextDecoder"])
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(ModelManager.hasRequiredModelFiles(in: folder))
    }

    func testHasRequiredModelFilesFalseWhenOneMissing() throws {
        let folder = try makeTempModelFolder(present: ["MelSpectrogram", "AudioEncoder"])
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(ModelManager.hasRequiredModelFiles(in: folder),
                       "when TextDecoder is missing it should judge the weights incomplete")
    }

    func testHasRequiredModelFilesFalseForEmptyFolder() throws {
        let folder = try makeTempModelFolder(present: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(ModelManager.hasRequiredModelFiles(in: folder))
    }

    // MARK: - Partial / cancelled download detection (regression for "shows 已下载 after cancel")

    func testHasRequiredModelFilesFalseWhenMlmodelcDirPresentButWeightMissing() throws {
        // Reproduces the on-disk bug signature: every `.mlmodelc` directory exists, but one
        // package's `weights/weight.bin` was never finished (the cancelled-download leftover).
        // The old `fileExists(.mlmodelc dir)` check passed this; completeness checking must reject it.
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try createCompleteModelPackage(named: "MelSpectrogram", in: folder)
        try createCompleteModelPackage(named: "TextDecoder", in: folder)
        try createPartialModelPackage(named: "AudioEncoder", in: folder, emptyWeight: false) // weights/ present, no weight.bin

        XCTAssertFalse(ModelManager.hasRequiredModelFiles(in: folder),
                       "a `.mlmodelc` whose weights/ has no weight.bin must NOT count as downloaded")
    }

    func testHasRequiredModelFilesFalseWhenWeightBlobIsEmpty() throws {
        // A zero-length weight.bin (interrupted mid-write) is also incomplete.
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try createCompleteModelPackage(named: "MelSpectrogram", in: folder)
        try createCompleteModelPackage(named: "AudioEncoder", in: folder)
        try createPartialModelPackage(named: "TextDecoder", in: folder, emptyWeight: true) // weights/weight.bin exists but 0 bytes

        XCTAssertFalse(ModelManager.hasRequiredModelFiles(in: folder),
                       "a zero-length weight.bin must NOT count as downloaded")
    }

    func testHasRequiredModelFilesFalseWhenDescriptorMissing() throws {
        // A `.mlmodelc` directory with no coremldata.bin descriptor is not a loadable package.
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try createCompleteModelPackage(named: "MelSpectrogram", in: folder)
        try createCompleteModelPackage(named: "AudioEncoder", in: folder)
        // TextDecoder: bare empty .mlmodelc directory (what a `fileExists` check used to accept).
        let bare = folder.appending(component: "TextDecoder.mlmodelc")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)

        XCTAssertFalse(ModelManager.hasRequiredModelFiles(in: folder),
                       "a bare `.mlmodelc` directory (no descriptor) must NOT count as downloaded")
    }

    func testCachedModelFolderNilWhenPartialDownloadLeftMlmodelcDirs() throws {
        // End-to-end through cachedModelFolder/isDownloaded: a variant folder whose `.mlmodelc`
        // directories are present but one weight blob is missing -> NOT found -> NOT downloaded.
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let variantFolder = repoRoot.appending(component: "openai_whisper-base")
        try createCompleteModelPackage(named: "MelSpectrogram", in: variantFolder)
        try createCompleteModelPackage(named: "TextDecoder", in: variantFolder)
        try createPartialModelPackage(named: "AudioEncoder", in: variantFolder, emptyWeight: false)

        XCTAssertNil(ModelManager.cachedModelFolder(for: "base", in: repoRoot),
                     "a partial/cancelled download must not be reported as a cached complete model")
    }

    func testIsCompleteModelPackagePassesWithoutWeightsDirectory() throws {
        // Not over-requiring: a `.mlmodelc` that legitimately ships no `weights/` directory
        // still counts as complete on its descriptor alone.
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mlmodelc = folder.appending(component: "MelSpectrogram.mlmodelc")
        try FileManager.default.createDirectory(at: mlmodelc, withIntermediateDirectories: true)
        try Data("descriptor".utf8).write(to: mlmodelc.appending(component: "coremldata.bin"))

        XCTAssertTrue(ModelManager.isCompleteModelPackage(at: mlmodelc),
                      "a package with a descriptor and no weights/ directory is still complete")
    }

    func testCachedModelFolderFindsByNormalizedNameWhenWeightsComplete() throws {
        // Put a really-named, weight-complete folder under the temp repo root; a hyphenated friendly name should hit it (equal after normalization).
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let variantFolder = repoRoot.appending(component: "openai_whisper-large-v3-v20240930_turbo")
        try createModelFiles(["MelSpectrogram", "AudioEncoder", "TextDecoder"], in: variantFolder)

        let found = ModelManager.cachedModelFolder(for: "large-v3-turbo", in: repoRoot)
        XCTAssertNotNil(found)
        // Compare the resolved paths, sidestepping equivalent-representation differences such as the /private prefix and trailing slashes.
        XCTAssertEqual(found?.resolvingSymlinksInPath().standardizedFileURL.path,
                       variantFolder.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testCachedModelFolderNilWhenWeightsIncomplete() throws {
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let variantFolder = repoRoot.appending(component: "openai_whisper-large-v3-v20240930_turbo")
        try createModelFiles(["MelSpectrogram"], in: variantFolder) // missing two

        XCTAssertNil(ModelManager.cachedModelFolder(for: "large-v3-turbo", in: repoRoot))
    }

    func testCachedModelFolderDoesNotMatchTurboFolderForLargeV3() throws {
        // The turbo folder name, after normalization, contains large-v3's normalized key, but should not be wrongly hit under "equal" matching.
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let turboFolder = repoRoot.appending(component: "openai_whisper-large-v3-v20240930_turbo")
        try createModelFiles(["MelSpectrogram", "AudioEncoder", "TextDecoder"], in: turboFolder)

        // Looking for large-v3, the repo only has turbo: should not hit under equal matching.
        XCTAssertNil(ModelManager.cachedModelFolder(for: "large-v3", in: repoRoot))
    }

    func testCachedModelFolderNilWhenNoMatchingFolder() throws {
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let variantFolder = repoRoot.appending(component: "openai_whisper-base")
        try createModelFiles(["MelSpectrogram", "AudioEncoder", "TextDecoder"], in: variantFolder)

        // Looking for large-v3-turbo, the repo only has base: should not hit.
        XCTAssertNil(ModelManager.cachedModelFolder(for: "large-v3-turbo", in: repoRoot))
    }

    func testCachedModelFolderNilWhenRepoDirAbsent() {
        let absent = FileManager.default.temporaryDirectory
            .appending(component: "sayit-modelmgr-absent-\(UUID().uuidString)")
        XCTAssertNil(ModelManager.cachedModelFolder(for: "large-v3-turbo", in: absent))
    }

    // MARK: - State machine (no network)

    @MainActor
    func testInitialStateNotDownloadedWhenNoCache() {
        // Under the real Application Support/SayIt/models this model is usually absent; if it happens to be already downloaded this assertion would become .downloaded,
        // so here we only assert the state is one of these two legal options (no network, no download).
        let mgr = ModelManager(model: "large-v3-turbo")
        XCTAssertTrue(mgr.state == .notDownloaded || mgr.state == .downloaded)
        XCTAssertEqual(mgr.model, "large-v3-turbo")
    }

    @MainActor
    func testSetModelSwitchesModelAndState() {
        let mgr = ModelManager(model: "large-v3-turbo")
        mgr.setModel("base")
        XCTAssertEqual(mgr.model, "base")
        XCTAssertTrue(mgr.state == .notDownloaded || mgr.state == .downloaded)
    }

    @MainActor
    func testCancelDownloadWhenIdleIsNoop() {
        let mgr = ModelManager(model: "small")
        let before = mgr.state
        mgr.cancelDownload()
        XCTAssertEqual(mgr.state, before)
    }

    // MARK: - Download-task identity guard (cancel button stays live after cancel+restart)

    /// Regression for the silent cancel-button no-op.
    ///
    /// A cancelled older task (taskA) can run its trailing `downloadTask = nil` cleanup
    /// AFTER a newer task (taskB) has already been stored. Before the fix that cleanup ran
    /// unconditionally and clobbered taskB's handle, so the next `cancelDownload()` saw
    /// `nil` and silently did nothing — the cancel button became a no-op.
    ///
    /// This drives that exact interleaving through the `launchDownloadTask` seam, then
    /// asserts taskB's handle survives taskA's late cleanup and `cancelDownload()` still
    /// cancels it. With the unconditional `downloadTask = nil`, the survival assertion fails.
    @MainActor
    func testStaleTaskCleanupDoesNotClobberRestartedTaskHandle() async {
        let mgr = ModelManager(model: "small")

        // --- taskA: a stand-in for the first (soon-cancelled) download ---
        // It blocks until released so we can control exactly when its cleanup runs.
        let releaseA = AsyncGate()
        let aStarted = AsyncGate()
        let taskA = mgr.launchDownloadTask {
            await aStarted.open()
            await releaseA.wait()
        }
        await aStarted.wait()
        // `Task` is a value type but conforms to Equatable/Hashable with identity semantics,
        // so `==` here compares task identity (the same handle), not the produced value.
        XCTAssertEqual(mgr.downloadTask, taskA, "taskA should be the current handle")

        // --- Cancel taskA (button press #1), then start taskB (restart) ---
        mgr.cancelDownload()
        XCTAssertNil(mgr.downloadTask, "cancelDownload clears the handle for the cancelled task")

        let releaseB = AsyncGate()
        let bStarted = AsyncGate()
        let taskB = mgr.launchDownloadTask {
            await bStarted.open()
            await releaseB.wait()
        }
        await bStarted.wait()
        XCTAssertEqual(mgr.downloadTask, taskB, "taskB should now be the current handle")

        // --- Let taskA finish: its trailing cleanup now runs AFTER taskB was stored ---
        await releaseA.open()
        await taskA.value  // wait for taskA (incl. its MainActor cleanup) to fully finish

        // The fix: taskA's stale cleanup must NOT clobber taskB's handle.
        XCTAssertEqual(
            mgr.downloadTask, taskB,
            "Stale taskA cleanup clobbered the restarted taskB handle (cancel button would become a no-op)"
        )

        // --- Cancel button press #2 must still cancel the live taskB ---
        mgr.cancelDownload()
        await releaseB.open()  // unblock taskB so it can observe the cancellation and exit
        await taskB.value
        XCTAssertTrue(taskB.isCancelled, "cancelDownload must still cancel the restarted taskB")
    }

    /// Normal (non-racing) path: a download task that finishes on its own clears its handle.
    @MainActor
    func testCompletedDownloadTaskClearsItsOwnHandle() async {
        let mgr = ModelManager(model: "small")
        let task = mgr.launchDownloadTask { /* completes immediately */ }
        await task.value
        // The trailing cleanup runs on the MainActor; yield so it can land.
        await Task.yield()
        XCTAssertNil(mgr.downloadTask, "a task that is still current should clear its own handle on completion")
    }

    // MARK: - Download error classification (cancel is not a failure; no raw NSError in the reason)

    func testIsCancellationTrueForSwiftCancellationError() {
        XCTAssertTrue(ModelManager.isCancellation(CancellationError()),
                      "a Swift CancellationError is a cancellation, not a failure")
    }

    func testIsCancellationTrueForNSURLErrorCancelled() {
        // The file-transfer layer (`Downloader.cancel()`) surfaces a real URLError(.cancelled),
        // i.e. domain NSURLErrorDomain, code -999. That shape must be treated as a cancellation.
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertTrue(ModelManager.isCancellation(cancelled),
                      "NSURLErrorCancelled (-999) must be treated as a cancellation")
    }

    func testIsCancellationTrueForRealURLErrorCancelled() {
        // The actual value `Downloader.cancel()` broadcasts is a Swift `URLError(.cancelled)`.
        XCTAssertTrue(ModelManager.isCancellation(URLError(.cancelled)),
                      "URLError(.cancelled) must be treated as a cancellation")
    }

    /// The real production cancel shape the previous fix MISSED: WhisperKit's `HubApi.httpGet`
    /// catches the underlying `URLError(.cancelled)` in a generic `catch` and re-throws it
    /// type-erased as the internal `Hub.HubClientError.downloadError(message)` (verified empirically:
    /// type `HubClientError`, domain `ArgmaxCore.Hub.HubClientError`, code 2, message the localized
    /// "cancelled"/"已取消"). We can't name that internal type, so `isCancellation` must recognize it by
    /// message. This reproduces both the English and Simplified-Chinese localized cancel descriptions
    /// (the two forms `URLError(.cancelled).localizedDescription` takes across the locales we ship).
    func testIsCancellationTrueForWrappedHubCancellationMessage() {
        // Stand-in for the type-erased Hub wrapper: a LocalizedError whose message carries the
        // residual cancellation text, exactly as the Hub layer's re-thrown error does.
        struct WrappedHubError: LocalizedError {
            let errorDescription: String?
        }
        for message in ["Download failed: cancelled", "Download failed: 已取消", "已取消", "The operation couldn’t be completed. (cancelled)"] {
            XCTAssertTrue(
                ModelManager.isCancellation(WrappedHubError(errorDescription: message)),
                "a wrapped Hub cancellation message (\(message)) must be classified as a cancellation, not a failure"
            )
        }
    }

    func testMessageLooksLikeCancellationRejectsUnrelatedMessages() {
        // Narrow on purpose: a real failure message must NOT be misread as a cancel.
        for message in ["network connection lost", "file not found", "HTTP error 500", "下载失败"] {
            XCTAssertFalse(
                ModelManager.messageLooksLikeCancellation(message),
                "an unrelated message (\(message)) must not be classified as cancellation"
            )
        }
    }

    func testIsCancellationFalseForGenuineNetworkError() {
        // A real failure (e.g. no connection) must NOT be mistaken for a cancellation.
        let genuine = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        XCTAssertFalse(ModelManager.isCancellation(genuine),
                       "a genuine network error must not be classified as cancellation")
    }

    func testIsCancellationFalseForUnrelatedError() {
        let other = NSError(domain: "SomeOtherDomain", code: -999, userInfo: nil)
        XCTAssertFalse(ModelManager.isCancellation(other),
                       "code -999 in a non-URL domain must not be classified as cancellation")
    }

    /// The user-facing `.failed(reason:)` must be a clean short message — never the raw NSError dump.
    /// (STTSettingsView renders `reason` verbatim via `Text(reason)`.) This drives the real download
    /// catch path with a genuine, immediate error by pointing the download at an unreachable repo so
    /// it fails fast without a multi-GB fetch, then asserts the reason carries no raw-error markers.
    @MainActor
    func testGenuineDownloadFailureReasonIsCleanNoRawNSError() async {
        let mgr = ModelManager(model: "tiny")
        // A bogus variant under the real repo resolves to no remote files; WhisperKit.download throws
        // a genuine (non-cancellation) error quickly. We only assert on the resulting reason shape.
        await mgr.download(model: "this-model-does-not-exist-\(UUID().uuidString)", force: true)

        guard case let .failed(reason) = mgr.state else {
            // If the environment has no network at all the call may still fail; tolerate any non-downloading
            // terminal state, but when it IS .failed the reason must be clean.
            return
        }
        XCTAssertFalse(reason.contains("NSURLErrorDomain"), "reason must not contain a raw NSError domain")
        XCTAssertFalse(reason.contains("Error Domain"), "reason must not contain a raw NSError dump")
        XCTAssertFalse(reason.contains("Code=-999"), "reason must not contain raw NSError codes")
        XCTAssertFalse(reason.contains("Code="), "reason must not contain raw NSError codes")
        // The clean canned message now resolves through the UI-language helper (i18n leak fix), so it
        // must equal one of the catalog forms — never some other / raw string. Under SwiftPM the
        // `.xcstrings` ships verbatim (no compiled `.lproj`), so the helper falls back to the English
        // default; on a built app it resolves per the selected Display Language. Accept either catalog
        // form so the test is stable across both environments.
        let expected = Set([
            "Download failed, please try again",
            ModelManager.localizedFailureReason("model.downloadFailed", fallback: "Download failed, please try again"),
        ])
        XCTAssertTrue(expected.contains(reason),
                      "a genuine failure shows the clean canned message resolved via the UI-language helper, got: \(reason)")
    }

    /// Regression for BUG A: a REAL, mid-flight cancel must NEVER become `.failed`, and must never
    /// stay stuck at `.downloading`.
    ///
    /// This drives the actual `download(force:)` path against the real `tiny` variant (smallest, so
    /// the transfer genuinely starts) and cancels it via `cancelDownload()` once `.downloading` is
    /// observed. On the PR branch the cancel surfaced as the type-erased
    /// `Hub.HubClientError.downloadError("已取消")`, which the old `isCancellation` mis-classified, so
    /// the terminal state was `.failed("下载失败，请重试")` — the exact BUG A symptom. The fix keys off
    /// `Task.isCancelled` (authoritative) and resolves via `resolveStateFromDisk()` (bypassing
    /// `refreshState()`'s `.downloading` early-return), so the cancel resolves to the real local state.
    ///
    /// Robust to environment: the *forbidden* outcomes are `.failed` (a user cancel is not a failure)
    /// and a stuck `.downloading`. If connectivity is absent and the request fails before we ever see
    /// `.downloading` (so nothing was cancelled), the assertion is skipped — we only assert when we
    /// actually observed and cancelled an in-flight download. If `tiny` happened to finish before the
    /// cancel landed, `.downloaded` is also acceptable.
    @MainActor
    func testRealMidFlightCancelIsNeverAFailure() async throws {
        let mgr = ModelManager(model: "tiny")

        let downloadTask = Task { await mgr.download(force: true) }

        // Wait until the download has actually entered `.downloading`, then cancel it.
        var observedDownloading = false
        for _ in 0..<400 {
            if case .downloading = mgr.state { observedDownloading = true; break }
            // Bail early if the task already finished (it can resolve without ever exposing
            // `.downloading` when there is no network, or once the transfer completes).
            if downloadTask.isCancelled { break }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
            await Task.yield()
        }

        guard observedDownloading else {
            // Never entered `.downloading` (no network / instant resolution). There was no in-flight
            // download to cancel, so this run can't exercise the regression; don't make a false claim.
            await downloadTask.value
            throw XCTSkip("download never entered .downloading (likely no network); cancel path not exercised")
        }

        mgr.cancelDownload()
        // cancelDownload() must immediately resolve away from `.downloading`.
        if case .downloading = mgr.state {
            XCTFail("cancelDownload() left the state stuck at .downloading")
        }

        // Let the cancelled download task fully unwind (its catch block runs and re-resolves state).
        await downloadTask.value

        switch mgr.state {
        case .notDownloaded, .downloaded:
            break  // both fine: a cancelled partial → .notDownloaded; a race-completed tiny → .downloaded
        case .downloading(let progress, _):
            XCTFail("state stuck at .downloading(progress: \(progress)) after a real cancel")
        case .failed(let reason):
            XCTFail("a real mid-flight user cancel must NOT become a failure (got .failed(\(reason)))")
        }
    }

    // MARK: - Failure reason follows the UI language (i18n leak regression)

    /// Regression for the i18n leak: the local-model download `.failed(reason:)` strings are rendered
    /// verbatim in the STT settings pane (`Text(reason)`), so they MUST resolve in the app's selected UI
    /// language via ``UILanguageLocalizer`` — not as a hardcoded literal. Before the fix the reasons were
    /// the bare Chinese literals "下载失败，请重试" / "下载完成但模型文件不完整", which stayed Chinese in English
    /// UI mode on a Chinese-system Mac.
    ///
    /// We can't compile `.lproj`s under SwiftPM (the catalog ships verbatim), so this stands up a real
    /// `en.lproj`/`zh-Hans.lproj` fixture bundle carrying the two `model.*` keys and drives the helper
    /// `ModelManager.localizedFailureReason` uses through it — proving the reason routes through the
    /// resolver and genuinely diverges per language.
    func testFailureReasonResolvesPerUILanguageNotHardcoded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagerFailureReason-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let table: [(code: String, failed: String, incomplete: String)] = [
            ("en", "Download failed, please try again", "Download finished but the model files are incomplete"),
            ("zh-Hans", "下载失败，请重试", "下载完成但模型文件不完整"),
        ]
        for entry in table {
            let lproj = root.appendingPathComponent("\(entry.code).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let strings = """
            "model.downloadFailed" = "\(entry.failed)";
            "model.downloadIncomplete" = "\(entry.incomplete)";

            """
            try strings.write(to: lproj.appendingPathComponent("Localizable.strings"),
                              atomically: true, encoding: .utf8)
        }
        let bundle = try XCTUnwrap(Bundle(url: root), "fixture bundle must load")

        // English UI: both reasons resolve to English, never the Chinese literal.
        let enFailed = UILanguageLocalizer.string("model.downloadFailed", defaultValue: "X",
                                                  bundle: bundle, language: .english)
        let enIncomplete = UILanguageLocalizer.string("model.downloadIncomplete", defaultValue: "X",
                                                      bundle: bundle, language: .english)
        XCTAssertEqual(enFailed, "Download failed, please try again")
        XCTAssertEqual(enIncomplete, "Download finished but the model files are incomplete")
        XCTAssertFalse(enFailed.contains("下载"), "English UI must NOT leak the Chinese failure reason")
        XCTAssertFalse(enIncomplete.contains("下载"), "English UI must NOT leak the Chinese incomplete reason")

        // Chinese UI: the same keys resolve to the Chinese forms — genuinely diverging.
        let zhFailed = UILanguageLocalizer.string("model.downloadFailed", defaultValue: "X",
                                                  bundle: bundle, language: .simplifiedChinese)
        let zhIncomplete = UILanguageLocalizer.string("model.downloadIncomplete", defaultValue: "X",
                                                      bundle: bundle, language: .simplifiedChinese)
        XCTAssertEqual(zhFailed, "下载失败，请重试")
        XCTAssertEqual(zhIncomplete, "下载完成但模型文件不完整")
        XCTAssertNotEqual(enFailed, zhFailed)
        XCTAssertNotEqual(enIncomplete, zhIncomplete)
    }

    /// The production helper `ModelManager.localizedFailureReason` never returns the bare key and never
    /// blanks: under SwiftPM (no compiled `.lproj`) it must fall through to the English fallback.
    func testLocalizedFailureReasonNeverReturnsBareKeyOrBlank() {
        for (key, fallback) in [("model.downloadFailed", "Download failed, please try again"),
                                ("model.downloadIncomplete", "Download finished but the model files are incomplete")] {
            let resolved = ModelManager.localizedFailureReason(key, fallback: fallback)
            XCTAssertFalse(resolved.isEmpty, "reason must never be blank")
            XCTAssertNotEqual(resolved, key, "reason must never be the bare key")
        }
    }

    // MARK: - Download-speed estimation (pure logic, no network)

    func testEstimatedDownloadBytesPositiveForKnownModels() {
        // Every known model must yield a positive size so the derived speed is sane.
        for model in ["tiny", "base", "small", "medium", "large-v3", "large-v3-turbo"] {
            XCTAssertGreaterThan(ModelManager.estimatedDownloadBytes(for: model), 0,
                                 "estimatedDownloadBytes(for: \(model)) should be > 0")
        }
    }

    func testEstimatedDownloadBytesOrderingBySize() {
        // Rough on-disk sizes should increase with model capacity.
        let tiny = ModelManager.estimatedDownloadBytes(for: "tiny")
        let base = ModelManager.estimatedDownloadBytes(for: "base")
        let small = ModelManager.estimatedDownloadBytes(for: "small")
        let medium = ModelManager.estimatedDownloadBytes(for: "medium")
        let large = ModelManager.estimatedDownloadBytes(for: "large-v3")
        XCTAssertLessThan(tiny, base)
        XCTAssertLessThan(base, small)
        XCTAssertLessThan(small, medium)
        XCTAssertLessThan(medium, large)
    }

    func testEstimatedDownloadBytesMatchesViaRealFolderName() {
        // Friendly name and its real repo folder name should bucket to the same estimate.
        XCTAssertEqual(
            ModelManager.estimatedDownloadBytes(for: "large-v3-turbo"),
            ModelManager.estimatedDownloadBytes(for: "openai_whisper-large-v3-v20240930_turbo")
        )
    }

    func testEstimatedDownloadBytesUnknownModelUsesPositiveFallback() {
        // Unknown names fall back to a generic positive size (so speed is still computable).
        XCTAssertGreaterThan(ModelManager.estimatedDownloadBytes(for: "distil-large-v3"), 0)
    }

    func testSmoothedSpeedFirstSampleReturnsInstantaneous() {
        // With no previous value the result is just deltaBytes / dt.
        let speed = ModelManager.smoothedSpeed(previous: nil, deltaBytes: 1_000, dt: 2)
        XCTAssertEqual(speed, 500, accuracy: 1e-9)
    }

    func testSmoothedSpeedBlendsPreviousWithInstantaneous() {
        // EMA: alpha*instantaneous + (1-alpha)*previous, alpha = 0.3.
        // instantaneous = 2000/1 = 2000; expected = 0.3*2000 + 0.7*1000 = 1300.
        let speed = ModelManager.smoothedSpeed(previous: 1_000, deltaBytes: 2_000, dt: 1, alpha: 0.3)
        XCTAssertEqual(speed, 1_300, accuracy: 1e-9)
    }

    func testSmoothedSpeedClampsNegativeDeltaToZero() {
        // A negative byte delta (e.g. fraction regressed) must not produce a negative rate.
        let speed = ModelManager.smoothedSpeed(previous: nil, deltaBytes: -500, dt: 1)
        XCTAssertEqual(speed, 0, accuracy: 1e-9)
    }

    // MARK: - State shape / Equatable (with speed)

    func testDownloadingStateEqualityConsidersSpeed() {
        // Same progress, different speed → not equal.
        XCTAssertNotEqual(
            ModelManager.State.downloading(progress: 0.5, speedBytesPerSec: nil),
            ModelManager.State.downloading(progress: 0.5, speedBytesPerSec: 1_000)
        )
        // Identical progress + speed → equal.
        XCTAssertEqual(
            ModelManager.State.downloading(progress: 0.5, speedBytesPerSec: 1_000),
            ModelManager.State.downloading(progress: 0.5, speedBytesPerSec: 1_000)
        )
        // Both nil speed, same progress → equal.
        XCTAssertEqual(
            ModelManager.State.downloading(progress: 0.5, speedBytesPerSec: nil),
            ModelManager.State.downloading(progress: 0.5, speedBytesPerSec: nil)
        )
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "sayit-modelmgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempModelFolder(present names: [String]) throws -> URL {
        let folder = try makeTempDir()
        try createModelFiles(names, in: folder)
        return folder
    }

    /// Creates a **complete** fake `.mlmodelc` package for each name inside `folder`.
    ///
    /// Mirrors the real on-disk layout of a finished WhisperKit download (inspected on this
    /// machine): each `<name>.mlmodelc` directory carries a non-empty `coremldata.bin` descriptor
    /// and a non-empty `weights/weight.bin` blob. This is what `hasRequiredModelFiles` now requires,
    /// so a folder built this way must be judged "downloaded".
    private func createModelFiles(_ names: [String], in folder: URL) throws {
        for name in names {
            try createCompleteModelPackage(named: name, in: folder)
        }
    }

    /// Writes a complete `<name>.mlmodelc` package (non-empty descriptor + non-empty weight blob).
    private func createCompleteModelPackage(named name: String, in folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let mlmodelc = folder.appending(component: "\(name).mlmodelc")
        let weightsDir = mlmodelc.appending(component: "weights")
        try fm.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        try Data("descriptor".utf8).write(to: mlmodelc.appending(component: "coremldata.bin"))
        try Data("weightblob".utf8).write(to: weightsDir.appending(component: "weight.bin"))
    }

    /// Writes a **partial** `<name>.mlmodelc` package that mimics an interrupted/cancelled
    /// download: the `.mlmodelc` directory and its `weights/` subdirectory exist, but the
    /// inner `weight.bin` is either absent or zero-length — the exact signature observed on disk
    /// for a cancelled `openai_whisper-base` download (`AudioEncoder.mlmodelc/weights/` empty).
    private func createPartialModelPackage(named name: String, in folder: URL, emptyWeight: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let mlmodelc = folder.appending(component: "\(name).mlmodelc")
        let weightsDir = mlmodelc.appending(component: "weights")
        try fm.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        try Data("descriptor".utf8).write(to: mlmodelc.appending(component: "coremldata.bin"))
        if emptyWeight {
            // weights/ exists with a zero-length weight.bin -> still incomplete.
            try Data().write(to: weightsDir.appending(component: "weight.bin"))
        }
        // else: weights/ exists but no weight.bin at all -> incomplete.
    }

    // MARK: - First-run auto-download predicate

    /// The first-run guidance only downloads for a brand-new local-engine user whose model is missing.
    func testShouldAutoDownloadOnlyForFreshLocalUserWithoutModel() {
        XCTAssertTrue(ModelManager.shouldAutoDownloadOnFirstRun(
            firstRun: true, sttMode: .local, isDownloaded: false),
            "fresh install, local engine, no model -> must auto-download")
    }

    /// An upgrading user whose model is already present must NOT get a spurious download.
    func testShouldNotAutoDownloadWhenModelAlreadyPresent() {
        XCTAssertFalse(ModelManager.shouldAutoDownloadOnFirstRun(
            firstRun: true, sttMode: .local, isDownloaded: true),
            "model already downloaded -> no auto-download")
    }

    /// A cloud-mode user must never trigger a local-model download on first run.
    func testShouldNotAutoDownloadInCloudMode() {
        XCTAssertFalse(ModelManager.shouldAutoDownloadOnFirstRun(
            firstRun: true, sttMode: .cloud, isDownloaded: false),
            "cloud engine -> no local-model download")
        XCTAssertFalse(ModelManager.shouldAutoDownloadOnFirstRun(
            firstRun: true, sttMode: .cloud, isDownloaded: true))
    }

    /// A non-first-run launch must never auto-download regardless of the other inputs.
    func testShouldNotAutoDownloadWhenNotFirstRun() {
        XCTAssertFalse(ModelManager.shouldAutoDownloadOnFirstRun(
            firstRun: false, sttMode: .local, isDownloaded: false),
            "subsequent launches must not re-trigger")
        XCTAssertFalse(ModelManager.shouldAutoDownloadOnFirstRun(
            firstRun: false, sttMode: .local, isDownloaded: true))
    }
}

/// A one-shot async gate for deterministically ordering steps across concurrent tasks in
/// tests: a task `wait()`s until another side calls `open()`. Re-`open()` is idempotent and
/// a `wait()` after `open()` returns immediately, so the two sides can race in either order.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until the gate is opened (returns immediately if already open).
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Opens the gate, resuming any current and future waiters.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
