import Foundation

/// 用户词典中的单条词条（替换/纠正规则的数据模型）。
///
/// 这是用户词典功能的**基础数据层**：只描述「一个规范写法 + 它的若干变体」这一事实，
/// 不含任何匹配/改写逻辑（匹配器、改写器与 STT/润色偏置在后续 PR 引入）。
///
/// 设计要点：
/// - **`Codable`**：直接 JSON 落盘（见 ``DictionaryStore``），字段语义稳定、可演进。
/// - **`Identifiable`**：以 `id`（`UUID`）做稳定标识，支持按 id 更新/删除与 UI 列表 diff。
/// - **`Sendable`**：可安全跨 actor 边界（由 ``DictionaryStore`` 这一 `actor` 持有）。
/// - **`Equatable`**：单测做 Codable 往返相等断言、UI diff 复用。
public struct DictionaryEntry: Codable, Identifiable, Sendable, Equatable {
    /// 词条的稳定唯一标识；用于按 id 更新/删除，跨持久化保持不变。
    public let id: UUID

    /// 规范写法（命中后应替换成的目标文本，如品牌名/术语的标准拼写）。
    public var canonical: String

    /// 会被纠正为 `canonical` 的变体写法（如同音错拼、口语化写法）。
    public var variants: [String]

    /// 匹配是否区分大小写。缺省 `false`（多数场景大小写无关）。
    public var caseSensitive: Bool

    /// 该词条是否启用。缺省 `true`；置 `false` 时保留数据但不参与匹配。
    public var enabled: Bool

    /// 生效范围：全局或限定到某个 app。
    public var scope: Scope

    /// 来源：用户手动添加 / 从一次编辑中学习得到。
    public var source: Source

    /// 创建时间；用于排序与「最近添加」等展示。
    public var createdAt: Date

    /// 命中并被应用的累计次数；用于排序/清理低频词条。缺省 `0`。
    public var usageCount: Int

    /// 词条生效范围。
    ///
    /// `app(bundleID:)` 携带关联值，Swift 会自动合成其 `Codable` 实现（编码为带
    /// 关联值的形态），无需手写 `CodingKeys`/`init(from:)`。两种 case 都覆盖单测往返。
    public enum Scope: Codable, Sendable, Equatable {
        /// 在所有 app 内生效。
        case global
        /// 仅在指定 bundle id 的 app 内生效。
        case app(bundleID: String)
    }

    /// 词条来源。落盘 `rawValue` 字符串，便于人读与向后兼容。
    public enum Source: String, Codable, Sendable {
        /// 用户在管理界面手动添加。
        case manual
        /// 从用户对一次输出结果的编辑中学习得到（后续 PR 使用）。
        case learnedFromEdit
    }

    /// 成员初始化器，带合理缺省：创建一条「手动 / 全局」词条只需传 `canonical`（+可选 `variants`）。
    ///
    /// - Note: `createdAt` 缺省取 `Date()`（即「此刻创建」），这对真实新建是合适的；
    ///   做相等断言的单测应显式传入固定 `Date` 以保证确定性。
    public init(
        id: UUID = UUID(),
        canonical: String,
        variants: [String] = [],
        caseSensitive: Bool = false,
        enabled: Bool = true,
        scope: Scope = .global,
        source: Source = .manual,
        createdAt: Date = Date(),
        usageCount: Int = 0
    ) {
        self.id = id
        self.canonical = canonical
        self.variants = variants
        self.caseSensitive = caseSensitive
        self.enabled = enabled
        self.scope = scope
        self.source = source
        self.createdAt = createdAt
        self.usageCount = usageCount
    }
}

/// 用户词典的根容器（整份词典 = 一组词条）。直接作为 JSON 文件的顶层结构落盘。
public struct UserDictionary: Codable, Sendable, Equatable {
    /// 全部词条；顺序即落盘/展示顺序。
    public var entries: [DictionaryEntry]

    /// - Parameter entries: 初始词条；缺省空词典。
    public init(entries: [DictionaryEntry] = []) {
        self.entries = entries
    }
}
