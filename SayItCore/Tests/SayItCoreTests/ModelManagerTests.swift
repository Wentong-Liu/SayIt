import XCTest
@testable import SayItCore

/// ModelManager 纯逻辑单测：variant 映射、缓存路径布局、归一化匹配、权重检测与状态机。
/// **不触发真实网络下载**（那需联网拉数 GB 模型，留到真机集成验证）。
final class ModelManagerTests: XCTestCase {

    // MARK: - 友好名 → 真实仓库 variant 文件夹名映射

    func testVariantMappingResolvesToRealRepoFolderNames() {
        // 友好名必须映射到 argmaxinc/whisperkit-coreml 仓库内真实存在的文件夹名
        // （经 HuggingFace HTTP 200 校验），否则 WhisperKit.download 解析不到、下载无声失败。
        XCTAssertEqual(ModelManager.variant(for: "large-v3-turbo"), "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(ModelManager.variant(for: "large-v3"), "openai_whisper-large-v3")
        XCTAssertEqual(ModelManager.variant(for: "medium"), "openai_whisper-medium")
        XCTAssertEqual(ModelManager.variant(for: "small"), "openai_whisper-small")
        XCTAssertEqual(ModelManager.variant(for: "base"), "openai_whisper-base")
        XCTAssertEqual(ModelManager.variant(for: "tiny"), "openai_whisper-tiny")
    }

    func testVariantMappingPassesThroughRealFolderName() {
        // 已是真实仓库文件夹名（含 openai_whisper- 前缀）应原样返回，不再重复加前缀。
        XCTAssertEqual(
            ModelManager.variant(for: "openai_whisper-large-v3-v20240930_turbo"),
            "openai_whisper-large-v3-v20240930_turbo"
        )
    }

    func testVariantMappingFallsBackToPrefixedNameForUnknownModel() {
        // 未知友好名按仓库命名约定加前缀兜底。
        XCTAssertEqual(ModelManager.variant(for: "distil-large-v3"), "openai_whisper-distil-large-v3")
    }

    // MARK: - 下载根目录 / 缓存布局（单一真相源）

    func testDownloadBaseIsApplicationSupportSayItModels() {
        // ~/Documents 受 TCC 保护，签名 hardened-runtime 非沙盒 App 无法写入；
        // 故根目录改用不受限的 Application Support/SayIt/models。
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
        // 访问 downloadBase 时应已确保目录存在，使 WhisperKit/HubApi 能直接写入。
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: ModelManager.downloadBase.path, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue,
                      "downloadBase 目录应在首次访问后存在")
    }

    func testRepoCacheDirectoryLayoutMatchesHubApi() {
        // HubApi.localRepoLocation 布局：downloadBase/<repoType=="models">/<repoId>
        let expected = ModelManager.downloadBase
            .appending(component: "models")
            .appending(component: "argmaxinc/whisperkit-coreml")
        XCTAssertEqual(ModelManager.repoCacheDirectory, expected)
    }

    func testModelRepoIsArgmaxWhisperKitCoreML() {
        XCTAssertEqual(ModelManager.modelRepo, "argmaxinc/whisperkit-coreml")
    }

    // MARK: - 归一化匹配（消除 - / _ / 大小写差异）

    func testNormalizedVariantKeyStripsSeparatorsAndCase() {
        XCTAssertEqual(ModelManager.normalizedVariantKey("large-v3-turbo"), "largev3turbo")
        XCTAssertEqual(ModelManager.normalizedVariantKey("openai_whisper-large-v3-v20240930_turbo"),
                       "openaiwhisperlargev3v20240930turbo")
    }

    func testNormalizedFolderNameEqualsNormalizedVariant() {
        // 真实仓库文件夹名归一化后应与 variant 归一化后**相等**（下载落盘即用此名）。
        let folderKey = ModelManager.normalizedVariantKey("openai_whisper-large-v3-v20240930_turbo")
        let variantKey = ModelManager.normalizedVariantKey(ModelManager.variant(for: "large-v3-turbo"))
        XCTAssertEqual(folderKey, variantKey,
                       "归一化后仓库文件夹名应等于归一化后的 variant")
    }

    // MARK: - 权重检测（用临时目录构造伪缓存）

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
        // 在临时 repo 根下放一个真实命名、权重齐全的文件夹；用连字符友好名应能命中（归一化后相等）。
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let variantFolder = repoRoot.appending(component: "openai_whisper-large-v3-v20240930_turbo")
        try createModelFiles(["MelSpectrogram", "AudioEncoder", "TextDecoder"], in: variantFolder)

        let found = ModelManager.cachedModelFolder(for: "large-v3-turbo", in: repoRoot)
        XCTAssertNotNil(found)
        // 比较解析后的路径，规避 /private 前缀与尾部斜杠等等价表示差异。
        XCTAssertEqual(found?.resolvingSymlinksInPath().standardizedFileURL.path,
                       variantFolder.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testCachedModelFolderNilWhenWeightsIncomplete() throws {
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let variantFolder = repoRoot.appending(component: "openai_whisper-large-v3-v20240930_turbo")
        try createModelFiles(["MelSpectrogram"], in: variantFolder) // 缺两个

        XCTAssertNil(ModelManager.cachedModelFolder(for: "large-v3-turbo", in: repoRoot))
    }

    func testCachedModelFolderDoesNotMatchTurboFolderForLargeV3() throws {
        // turbo 文件夹名归一化后包含 large-v3 的归一化键，但用「相等」匹配后不应被误命中。
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let turboFolder = repoRoot.appending(component: "openai_whisper-large-v3-v20240930_turbo")
        try createModelFiles(["MelSpectrogram", "AudioEncoder", "TextDecoder"], in: turboFolder)

        // 找 large-v3，仓库里只有 turbo：相等匹配下不应命中。
        XCTAssertNil(ModelManager.cachedModelFolder(for: "large-v3", in: repoRoot))
    }

    func testCachedModelFolderNilWhenNoMatchingFolder() throws {
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let variantFolder = repoRoot.appending(component: "openai_whisper-base")
        try createModelFiles(["MelSpectrogram", "AudioEncoder", "TextDecoder"], in: variantFolder)

        // 找 large-v3-turbo，仓库里只有 base：不应命中。
        XCTAssertNil(ModelManager.cachedModelFolder(for: "large-v3-turbo", in: repoRoot))
    }

    func testCachedModelFolderNilWhenRepoDirAbsent() {
        let absent = FileManager.default.temporaryDirectory
            .appending(component: "sayit-modelmgr-absent-\(UUID().uuidString)")
        XCTAssertNil(ModelManager.cachedModelFolder(for: "large-v3-turbo", in: absent))
    }

    // MARK: - 状态机（无网络）

    @MainActor
    func testInitialStateNotDownloadedWhenNoCache() {
        // 真实 Application Support/SayIt/models 下通常无该模型；若恰好已下载本断言会变 .downloaded，
        // 故这里只断言状态是这两种合法之一（不联网、不下载）。
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

    // MARK: - 辅助

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

    /// 在 `folder` 内为每个名字创建一个伪 `.mlmodelc` 目录（detectModelURL 直接命中 .mlmodelc 路径）。
    private func createModelFiles(_ names: [String], in folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            let mlmodelc = folder.appending(component: "\(name).mlmodelc")
            try fm.createDirectory(at: mlmodelc, withIntermediateDirectories: true)
        }
    }
}
