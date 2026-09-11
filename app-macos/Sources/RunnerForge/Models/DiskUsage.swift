import Foundation

/// Which side of the Cleanup page an item belongs to.
public enum DiskCategory: String, Sendable {
    /// Never deleted. Deleting it is what makes the next run slow.
    case keep
    /// Deleted on close and on demand.
    case purge
}

/// One row on the Cleanup page.
public struct DiskUsageItem: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let description: String
    public let category: DiskCategory
    public let bytes: Int64

    /// Why this item is kept, shown so KEEP does not look like clutter.
    public let reason: String?

    public var humanBytes: String { DiskUsageItem.format(bytes: bytes) }

    public init(description: String, category: DiskCategory, bytes: Int64, reason: String? = nil) {
        self.description = description
        self.category = category
        self.bytes = bytes
        self.reason = reason
    }

    public static func format(bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }
}

/// The Cleanup page's whole model: two explicit lists and a total.
public struct DiskUsage: Sendable {
    public let keep: [DiskUsageItem]
    public let purge: [DiskUsageItem]

    public init(keep: [DiskUsageItem] = [], purge: [DiskUsageItem] = []) {
        self.keep = keep
        self.purge = purge
    }

    public var keepBytes: Int64 { keep.reduce(0) { $0 + $1.bytes } }
    public var reclaimableBytes: Int64 { purge.reduce(0) { $0 + $1.bytes } }

    public var humanKeepBytes: String { DiskUsageItem.format(bytes: keepBytes) }
    public var humanReclaimableBytes: String { DiskUsageItem.format(bytes: reclaimableBytes) }
}
