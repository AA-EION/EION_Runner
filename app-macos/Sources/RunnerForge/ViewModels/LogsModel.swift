import Foundation
import Observation

/// Drives the Logs page.
///
/// Everything shown here has already been through LogBus redaction: secrets are
/// replaced by value AND by shape, so a credential cannot reach this page even
/// if some service forgets to be careful.
@MainActor
@Observable
public final class LogsModel {
    private let store: ForgeStore

    public var entries: [LogEntry] = []
    public var minimumLevel: LogLevel = .info
    public var sourceFilter = ""
    public var searchText = ""
    public var isFollowing = true
    public var statusMessage: String?

    private var pollTask: Task<Void, Never>?

    public init(store: ForgeStore) { self.store = store }

    public var sources: [String] {
        Array(Set(entries.map(\.source))).sorted()
    }

    public var filtered: [LogEntry] {
        entries.filter { entry in
            guard entry.level >= minimumLevel else { return false }
            if !sourceFilter.isEmpty, entry.source != sourceFilter { return false }
            if !searchText.isEmpty,
               !entry.message.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
    }

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        guard isFollowing else { return }
        entries = await store.services.logBus.snapshot()
    }

    public func clear() async {
        await store.services.logBus.clear()
        entries = []
    }

    /// Saves the log to a file the user can attach to a bug report. The text is
    /// the redacted text, not a second rendering from raw entries.
    public func save(to path: String) async {
        do {
            let text = await store.services.logBus.plainText()
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            statusMessage = "Saved \(text.utf8.count) bytes to \(path)."
        } catch {
            statusMessage = "Could not save: \(error)"
        }
    }

    public func defaultSavePath() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return desktop.appendingPathComponent("runnerforge-\(stamp).log").path
    }
}
