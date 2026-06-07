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
                       "downloadBase 必须位于 Application Support/SayIt/models（避开 TCC 保护的 Documents）")
    }

    func testDownloadBaseDirectoryExists() {
        // Accessing downloadBase should have ensured the directory exists, so WhisperKit/HubApi can write directly.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: ModelManager.downloadBase.path, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue,
                      "downloadBase 目录应在首次访问后存在")
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
                       "归一化后仓库文件夹名应等于归一化后的 variant")
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
                       "缺少 TextDecoder 时应判定权重不齐")
    }

    func testHasRequiredModelFilesFalseForEmptyFolder() throws {
        let folder = try makeTempModelFolder(present: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(ModelManager.hasRequiredModelFiles(in: folder))
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

    /// Creates a fake `.mlmodelc` directory for each name inside `folder` (detectModelURL directly hits the .mlmodelc path).
    private func createModelFiles(_ names: [String], in folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            let mlmodelc = folder.appending(component: "\(name).mlmodelc")
            try fm.createDirectory(at: mlmodelc, withIntermediateDirectories: true)
        }
    }
}
