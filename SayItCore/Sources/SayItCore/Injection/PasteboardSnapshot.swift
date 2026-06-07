import AppKit

/// 对 NSPasteboard 的最小抽象，便于在不触碰系统真实剪贴板的情况下做单测。
/// 只暴露快照/还原文本注入需要的能力。
@MainActor
public protocol PasteboardProtocol: AnyObject {
    /// 当前 changeCount，用于检测剪贴板是否在注入期间被其它进程改写。
    var changeCount: Int { get }
    /// 当前所有 item 的「type → data」快照。用于完整保存任意类型（不只是纯文本）。
    func snapshotItems() -> [[String: Data]]
    /// 清空并按快照还原所有 item。
    func restoreItems(_ items: [[String: Data]])
    /// 读取纯文本（NSPasteboard.string(forType: .string)）。
    func string() -> String?
    /// 清空并写入纯文本，返回 changeCount。
    @discardableResult
    func writeString(_ text: String) -> Int
}

/// 基于系统 NSPasteboard.general 的实现。
@MainActor
public final class SystemPasteboard: PasteboardProtocol {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshotItems() -> [[String: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var map: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type.rawValue] = data
                }
            }
            return map
        }
    }

    public func restoreItems(_ items: [[String: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let newItems: [NSPasteboardItem] = items.map { map in
            let item = NSPasteboardItem()
            for (rawType, data) in map {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        pasteboard.writeObjects(newItems)
    }

    public func string() -> String? {
        pasteboard.string(forType: .string)
    }

    @discardableResult
    public func writeString(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }
}

/// 剪贴板原内容的快照，注入完成后用于还原。
/// 抽成独立纯逻辑类型，save/restore 行为可在不依赖系统的前提下单测（注入假 pasteboard）。
@MainActor
public struct PasteboardBackup {
    /// 保存时记录的 item 快照。
    public let items: [[String: Data]]
    /// 保存时的 changeCount。还原前据此判断剪贴板是否已被外部改写。
    public let changeCountAtSave: Int

    private init(items: [[String: Data]], changeCountAtSave: Int) {
        self.items = items
        self.changeCountAtSave = changeCountAtSave
    }

    /// 从 pasteboard 捕获当前内容快照。
    public static func capture(from pasteboard: PasteboardProtocol) -> PasteboardBackup {
        PasteboardBackup(
            items: pasteboard.snapshotItems(),
            changeCountAtSave: pasteboard.changeCount
        )
    }

    /// 把快照内容还原回 pasteboard。
    /// 总是执行还原（即使快照为空也清空，回到捕获时的状态）。
    public func restore(to pasteboard: PasteboardProtocol) {
        pasteboard.restoreItems(items)
    }
}
