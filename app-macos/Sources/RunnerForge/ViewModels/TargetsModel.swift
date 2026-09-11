import Foundation
import Observation

/// Drives the Targets page: which repositories Runner Forge serves, and which
/// runner classes this Mac hosts for them.
@MainActor
@Observable
public final class TargetsModel {
    private let store: ForgeStore

    public var newRepo = ""
    public var statusMessage: String?
    public var isVerifying = false

    /// Per-repo result of the access check, so a typo shows up here rather than
    /// as a job that queues forever.
    public var accessResults: [String: String] = [:]

    public init(store: ForgeStore) { self.store = store }

    public var owner: String {
        get { store.config.github.owner }
        set { store.config.github.owner = newValue; store.markDirty() }
    }

    public var repos: [String] { store.config.github.repos }

    public func addRepo() {
        let trimmed = newRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // "owner/repo" pasted whole is the common case; keep only the repo part
        // so the two fields never disagree about the owner.
        let name = trimmed.contains("/") ? String(trimmed.split(separator: "/").last!) : trimmed
        guard !store.config.github.repos.contains(name) else {
            statusMessage = "\(name) is already in the list."
            return
        }

        store.config.github.repos.append(name)
        store.markDirty()
        newRepo = ""
        statusMessage = nil
    }

    public func removeRepo(_ name: String) {
        store.config.github.repos.removeAll { $0 == name }
        accessResults[name] = nil
        store.markDirty()
    }

    public func verifyAccess() async {
        guard !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }

        accessResults = [:]
        for repo in repos {
            do {
                accessResults[repo] = try await store.services.appService
                    .verifyRepositoryAccess(config: store.config, repo: repo)
            } catch {
                accessResults[repo] = "FAIL: \(error)"
            }
        }
    }

    public func setEnabled(_ runnerClass: RunnerClass, _ enabled: Bool) {
        var entry = store.runnerConfig(for: runnerClass)
        entry.enabled = enabled
        store.updateRunnerConfig(entry)
    }

    public func setReplicas(_ runnerClass: RunnerClass, _ count: Int) {
        var entry = store.runnerConfig(for: runnerClass)
        // The iLok classes are pinned to one replica: there is one dongle, and a
        // second replica would contend for it rather than double throughput.
        entry.replicas = runnerClass.replicasAreFixed
            ? 1
            : min(max(count, runnerClass.minReplicas), runnerClass.maxReplicas)
        store.updateRunnerConfig(entry)
    }

    public func classes() -> [RunnerClass] { store.hostableClasses }
}
