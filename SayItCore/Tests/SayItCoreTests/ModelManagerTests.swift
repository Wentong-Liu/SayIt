import XCTest
@testable import SayItCore

/// ModelManager 纯逻辑单测：variant 映射、缓存路径布局、归一化匹配、权重检测与状态机。
/// **不触发真实网络下载**（那需联网拉数 GB 模型，留到真机集成验证）。
final class ModelManagerTests: XCTestCase {

    // MARK: - 友好名 → variant 映射

    func testVariantMappingIsIdentityForKnownModels() {
        XCTAssertEqual(ModelManager.variant(for: "large-v3-turbo"), "large-v3-turbo")
        XCTAssertEqual(ModelManager.variant(for: "large-v3"), "large-v3")
        XCTAssertEqual(ModelManager.variant(for: "medium"), "medium")
        XCTAssertEqual(ModelManager.variant(for: "small"), "small")
        XCTAssertEqual(ModelManager.variant(for: "base"), "base")
    }

    // MARK: - 下载根目录 / 缓存布局（单一真相源）

    func testDownloadBaseIsDocumentsHuggingface() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let expected = documents.appending(component: "huggingface")
        XCTAssertEqual(ModelManager.downloadBase, expected,
                       "downloadBase 必须与 WhisperKit 默认（Documents/huggingface）一致")
    }

    func testRepoCacheDirectoryLayoutMatchesHubApi() {
        // HubApi.localRepoLocation 布局：downloadBase/<repoType>/<repoId>
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
        XCTAssertEqual(ModelManager.normalizedVariantKey("openai_whisper-large-v3_turbo"),
                       "openaiwhisperlargev3turbo")
    }

    func testNormalizedFolderNameContainsNormalizedVariant() {
        // 仓库文件夹名（下划线）应能被友好名（连字符）归一化后命中。
        let folderKey = ModelManager.normalizedVariantKey("openai_whisper-large-v3_turbo")
        let variantKey = ModelManager.normalizedVariantKey(ModelManager.variant(for: "large-v3-turbo"))
        XCTAssertTrue(folderKey.contains(variantKey),
                      "归一化后仓库文件夹名应包含归一化后的 variant")
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
        // 在临时 repo 根下放一个下划线命名、权重齐全的文件夹；用连字符友好名应能命中。
        let repoRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let variantFolder = repoRoot.appending(component: "openai_whisper-large-v3_turbo")
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
        let variantFolder = repoRoot.appending(component: "openai_whisper-large-v3_turbo")
        try createModelFiles(["MelSpectrogram"], in: variantFolder) // 缺两个

        XCTAssertNil(ModelManager.cachedModelFolder(for: "large-v3-turbo", in: repoRoot))
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
        // 真实 ~/Documents/huggingface 下通常无该模型；若恰好已下载本断言会变 .downloaded，
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
