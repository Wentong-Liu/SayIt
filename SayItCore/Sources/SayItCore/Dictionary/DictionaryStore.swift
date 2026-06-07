import Foundation
import os

/// 用户词典的持久化存储（基础层，**不接管线、不含匹配逻辑**）。
///
/// 职责：把 ``UserDictionary`` 以 JSON 落盘到 `Application Support/SayIt/dictionary.json`，
/// 首次访问时一次性载入到内存缓存，之后每次增删改都**原子写盘**并发**变更通知**。
///
/// 设计要点：
/// - **`actor`**：磁盘读写串行化，CRUD 全部经 actor 隔离天然并发安全（首个 public 且发通知的 actor）。
/// - **App Support 目录复用**：默认根目录沿用 ``ModelManager/downloadBase`` 同款解析
///   （`Application Support/SayIt`，取不到时回落到 `Caches/SayIt`），与模型缓存同根，不另立目录方案。
/// - **可注入**：`baseDirectory` / `fileName` / `notificationCenter` / `fileManager` 均可注入，
///   单测传临时目录与独立通知中心，绝不碰真实用户数据。
/// - **变更通知**：镜像 ``AppConfig/didChangeNotification`` 的命名与「值确有变化才发」语义；
///   每次真正改动状态的 CRUD 成功后投递 ``DictionaryStore/didChangeNotification``。
///   `object` 传 `nil`（`actor` 实例非 `Sendable`，不可作通知 object；监听方收到后用 ``all()`` 重读）。
/// - **永不崩溃**：文件缺失或解码失败时静默以空词典起步（记日志后继续），落盘失败只记日志不抛出——
///   基础层不得把 I/O 错误传染给调用方。
public actor DictionaryStore {
    /// 词典发生变化时投递的通知。镜像 ``AppConfig/didChangeNotification`` 的命名风格。
    ///
    /// 在每次真正改动词典的 CRUD（add / update / remove / replaceAll）成功后投递。
    /// `object` 为 `nil`（`actor` 不可作通知 object）；监听方收到后调用 ``all()`` 重读最新内容。
    public static let didChangeNotification = Notification.Name("com.liuwentong.SayIt.DictionaryStoreDidChange")

    /// 默认词典根目录：`Application Support/SayIt`（与 ``ModelManager/downloadBase`` 同根）。
    ///
    /// 解析方式与 ``ModelManager`` 一致：取 Application Support（缺失则创建），失败回落到 Caches，
    /// 始终避开受 TCC 保护的 `~/Documents`。词典文件落在此目录下的 `dictionary.json`。
    nonisolated public static let defaultBaseDirectory: URL = {
        let fm = FileManager.default
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport.appending(component: "SayIt")
        }
        // 极端情况下取不到 Application Support：回退到缓存目录，仍避开受 TCC 保护的 Documents。
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appending(component: "SayIt")
    }()

    private let baseDirectory: URL
    private let fileURL: URL
    private let notificationCenter: NotificationCenter
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.liuwentong.SayIt", category: "dictionary")

    /// 内存缓存；`nil` 表示尚未从磁盘载入（懒加载一次）。
    private var cache: UserDictionary?

    /// - Parameters:
    ///   - baseDirectory: 词典文件所在目录；默认 ``defaultBaseDirectory``，单测传临时目录。
    ///   - fileName: 词典文件名；默认 `"dictionary.json"`。
    ///   - notificationCenter: 变更通知中心；默认 `.default`，单测可传独立实例观察。
    ///   - fileManager: 文件系统句柄；默认 `.default`。
    public init(
        baseDirectory: URL = DictionaryStore.defaultBaseDirectory,
        fileName: String = "dictionary.json",
        notificationCenter: NotificationCenter = .default,
        fileManager: FileManager = .default
    ) {
        self.baseDirectory = baseDirectory
        self.fileURL = baseDirectory.appending(component: fileName)
        self.notificationCenter = notificationCenter
        self.fileManager = fileManager
    }

    // MARK: - CRUD

    /// 返回当前全部词条（必要时先从磁盘载入）。
    public func all() -> [DictionaryEntry] {
        ensureLoaded().entries
    }

    /// 追加一条词条；随后落盘并发变更通知。
    public func add(_ entry: DictionaryEntry) {
        var dict = ensureLoaded()
        dict.entries.append(entry)
        commit(dict)
    }

    /// 按 `id` 替换已存在的词条；仅当找到**且内容确有变化**时才落盘+发通知。
    public func update(_ entry: DictionaryEntry) {
        var dict = ensureLoaded()
        guard let index = dict.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        guard dict.entries[index] != entry else { return }
        dict.entries[index] = entry
        commit(dict)
    }

    /// 按 `id` 删除词条；仅当确有删除发生时才落盘+发通知。
    public func remove(id: UUID) {
        var dict = ensureLoaded()
        let before = dict.entries.count
        dict.entries.removeAll { $0.id == id }
        guard dict.entries.count != before else { return }
        commit(dict)
    }

    /// 用给定词条整体替换词典；落盘并发变更通知（无条件视作一次变更）。
    public func replaceAll(_ entries: [DictionaryEntry]) {
        // 先 ensureLoaded() 以保证基目录已建（它是唯一建目录处）；否则当 replaceAll 是
        // 全新 store 上的首个操作时，目录缺失会导致原子写盘失败、数据只留在内存而静默丢失。
        ensureLoaded()
        commit(UserDictionary(entries: entries))
    }

    // MARK: - 载入 / 落盘 / 通知

    /// 懒加载一次：首访时建目录、读盘解码；文件缺失或损坏则以空词典起步（记日志，绝不抛/崩）。
    @discardableResult
    private func ensureLoaded() -> UserDictionary {
        if let cache { return cache }

        // 确保目录存在，使后续原子写盘可直接落地。
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            // 文件缺失（首次运行）：以空词典起步。
            let empty = UserDictionary()
            cache = empty
            return empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(UserDictionary.self, from: data)
            cache = decoded
            return decoded
        } catch {
            // 文件损坏/无法解码：记日志并以空词典起步，绝不崩溃。
            logger.error("Failed to load dictionary at \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public). Starting empty.")
            let empty = UserDictionary()
            cache = empty
            return empty
        }
    }

    /// 更新内存缓存 → 原子写盘 → 发变更通知。落盘失败只记日志，不抛出。
    private func commit(_ dict: UserDictionary) {
        cache = dict
        persist(dict)
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }

    /// 原子写盘：`.atomic` 先写临时文件再 rename，故磁盘上永不残留半截/损坏文件。
    ///
    /// `JSONEncoder` 用 `.sortedKeys + .prettyPrinted` 输出稳定、可 diff 的 JSON；
    /// 日期编码用默认 `.deferredToDate`，与解码默认一致。失败仅记日志，不传染给调用方。
    private func persist(_ dict: UserDictionary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(dict)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Failed to persist dictionary to \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public).")
        }
    }
}
