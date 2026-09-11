import Foundation
import Observation

/// Drives the Preflight page.
@MainActor
@Observable
public final class PreflightModel {
    private let store: ForgeStore

    public var checks: [PreflightCheck] = []
    public var isRunning = false
    public var lastRunAt: Date?
    public var fixMessage: String?

    public init(store: ForgeStore) { self.store = store }

    public var failures: [PreflightCheck] { checks.filter { $0.status == .fail } }
    public var warnings: [PreflightCheck] { checks.filter { $0.status == .warn } }

    /// A hard block cannot be fixed by anything the app can do — an Intel Mac is
    /// the archetype. The UI says so instead of offering a Fix that would fail.
    public var hardBlocks: [PreflightCheck] { checks.filter(\.isHardBlock) }

    public var canStartRunners: Bool { !checks.isEmpty && failures.isEmpty }

    /// Class ids that at least one failing check blocks.
    public var blockedClassIds: Set<String> {
        Set(failures.flatMap(\.blocksClasses))
    }

    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        checks = await store.services.preflightService.runAll(config: store.config)
        lastRunAt = Date()

        let failed = failures.count
        if failed == 0 {
            await store.services.logBus.info("preflight", "all \(checks.count) checks pass")
        } else {
            await store.services.logBus.warning(
                "preflight", "\(failed) of \(checks.count) checks failed")
        }
    }

    /// The only auto-fixes offered are ones with an exact, non-destructive
    /// command. Anything else states the manual step rather than guessing.
    public func fix(_ check: PreflightCheck) async {
        guard check.autoFixable else { return }
        fixMessage = nil

        switch check.name {
        case "Rosetta 2":
            let result = try? await store.services.processRunner.run(
                "/usr/sbin/softwareupdate",
                arguments: ["--install-rosetta", "--agree-to-license"],
                logSource: "preflight")
            fixMessage = (result?.succeeded == true)
                ? "Rosetta 2 installed."
                : "Rosetta 2 install failed; see the Logs page."

        case "Free disk space":
            _ = try? await store.services.sweeperService.purge(config: store.config)
            fixMessage = "Sweeper run. Re-checking free space."

        case "System sleep":
            // caffeinate is held for the app's lifetime by RunnerForgeApp; this
            // only reports that the assertion exists, it does not change pmset.
            fixMessage = "Runner Forge already holds a caffeinate assertion while it is open."

        default:
            fixMessage = check.fixHint
        }

        await run()
    }
}
