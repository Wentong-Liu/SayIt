import AppKit

/// A minimal abstraction over NSPasteboard, to allow unit testing without touching the real system pasteboard.
/// It only exposes the capabilities needed for snapshot/restore text injection.
@MainActor
public protocol PasteboardProtocol: AnyObject {
    /// Current changeCount, used to detect whether the pasteboard was overwritten by another process during injection.
    var changeCount: Int { get }
    /// A "type -> data" snapshot of all current items. Used to fully preserve arbitrary types (not just plain text).
    func snapshotItems() -> [[String: Data]]
    /// Clears and restores all items from a snapshot.
    func restoreItems(_ items: [[String: Data]])
    /// Reads plain text (NSPasteboard.string(forType: .string)).
    func string() -> String?
    /// Clears and writes plain text, returning the changeCount.
    @discardableResult
    func writeString(_ text: String) -> Int
}

/// Implementation based on the system NSPasteboard.general.
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

/// A snapshot of the pasteboard's original content, used to restore it after injection completes.
/// Extracted into a standalone pure-logic type so save/restore behavior can be unit-tested without depending on the system (by injecting a fake pasteboard).
@MainActor
public struct PasteboardBackup {
    /// The item snapshot recorded at save time.
    public let items: [[String: Data]]
    /// The changeCount at save time. Used before restoring to decide whether the pasteboard was overwritten externally.
    public let changeCountAtSave: Int

    private init(items: [[String: Data]], changeCountAtSave: Int) {
        self.items = items
        self.changeCountAtSave = changeCountAtSave
    }

    /// Captures a snapshot of the current content from the pasteboard.
    public static func capture(from pasteboard: PasteboardProtocol) -> PasteboardBackup {
        PasteboardBackup(
            items: pasteboard.snapshotItems(),
            changeCountAtSave: pasteboard.changeCount
        )
    }

    /// Restores the snapshot content back to the pasteboard.
    /// Always performs the restore (even an empty snapshot clears it, returning to the state at capture time).
    public func restore(to pasteboard: PasteboardProtocol) {
        pasteboard.restoreItems(items)
    }
}
