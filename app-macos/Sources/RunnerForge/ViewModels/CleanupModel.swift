import Foundation
import Observation

/// Drives the Cleanup page: two explicit lists, never a blanket prune.
@MainActor
@Observable
public final class CleanupModel {
    private let store: ForgeStore

    public var usage = DiskUsage()
    public var isSurveying = false
    public var isPurging = false
    public var lastReclaimed: Int64?
    public var errorMessage: String?

    public init(store: ForgeStore) { self.store = store }

    /// Stated on the page so the absence of a "clean everything" button reads as
    /// a decision rather than a missing feature.
    public static let pruneNote = """
        Runner Forge never runs `docker system prune -a`. That command deletes base images and build \
        caches shared with everything else on this machine, and the next run then pays tens of minutes \
        to rebuild what it threw away. Only the items in PURGE are ever deleted.
        """

    public func survey() async {
        guard !isSurveying else { return }
        isSurveying = true
        defer { isSurveying = false }

        do {
            usage = try await store.services.sweeperService.survey(config: store.config)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func purge() async {
        guard !isPurging else { return }
        isPurging = true
        defer { isPurging = false }

        do {
            lastReclaimed = try await store.services.sweeperService.purge(config: store.config)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        await survey()
    }

    public var purgeOnExit: Bool {
        get { store.config.retention.purgeOnExit }
        set { store.config.retention.purgeOnExit = newValue; store.markDirty() }
    }

    public var maxDiskGb: Int {
        get { store.config.limits.maxDiskGb }
        set { store.config.limits.maxDiskGb = max(10, newValue); store.markDirty() }
    }

    public var logRetentionDays: Int {
        get { store.config.retention.logRetentionDays }
        set { store.config.retention.logRetentionDays = max(1, newValue); store.markDirty() }
    }
}
