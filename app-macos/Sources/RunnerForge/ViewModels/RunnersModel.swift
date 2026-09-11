import Foundation
import Observation

/// Drives the Runners page: start/stop, live replica state, the self-test, and
/// the stray-survivor block.
@MainActor
@Observable
public final class RunnersModel {
    private let store: ForgeStore

    public var replicas: [ReplicaStatus] = []
    public var isBusy = false
    public var statusMessage: String?

    public var blockedByStraySurvivors = false
    public var straySurvivorDetails: [String] = []

    public var selfTestProgress: String?
    public var selfTestRunning = false
    public var selfTestResult: SelfTestResult?

    private var pollTask: Task<Void, Never>?

    public init(store: ForgeStore) { self.store = store }

    public var lastProof: SelfTestResult? { selfTestResult ?? store.config.verification.lastProof }

    public var classes: [RunnerClass] { store.hostableClasses }

    public func replicas(for runnerClass: RunnerClass) -> [ReplicaStatus] {
        replicas.filter { $0.classId == runnerClass.classId }
    }

    public func isRunning(_ runnerClass: RunnerClass) -> Bool {
        replicas(for: runnerClass).contains { $0.state != .stopped }
    }

    /// Polls the supervisor rather than having it push: the supervisor is an
    /// actor with no opinion about the UI, and a 2-second poll is cheaper than
    /// hopping to the main actor on every runner state change.
    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Called from the view's onDisappear and from app teardown. There is
    /// deliberately no deinit doing this: deinit is nonisolated, and reaching
    /// into main-actor state from it is not something Swift 6 allows.
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        replicas = await store.services.supervisor.currentReplicas()
        blockedByStraySurvivors = await store.services.supervisor.blockedByStraySurvivors
        straySurvivorDetails = await store.services.supervisor.straySurvivorDetails
    }

    public func acknowledgeStraySurvivors() async {
        await store.services.supervisor.acknowledgeStraySurvivors()
        await refresh()
    }

    public func start(_ runnerClass: RunnerClass) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        await store.services.supervisor.startClass(config: store.config, runnerClass: runnerClass)
        await refresh()
    }

    public func stop(_ runnerClass: RunnerClass) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        await store.services.supervisor.stopClass(runnerClass)
        await refresh()
    }

    public func startAllEnabled() async {
        for runnerClass in classes where store.runnerConfig(for: runnerClass).enabled {
            await start(runnerClass)
        }
    }

    public func stopAll() async {
        for runnerClass in classes { await stop(runnerClass) }
    }

    /// Drains in-flight jobs, then reaps. Used by the menu bar and by app close.
    public func drainAndReap(timeout: TimeInterval = 120) async {
        statusMessage = "Draining…"
        await store.services.supervisor.drain(timeout: timeout) { [weak self] detail in
            Task { @MainActor in self?.statusMessage = detail }
        }

        let outcome = try? await store.services.reaperService.reap(config: store.config)
        statusMessage = switch outcome {
        case .clean: "Drained. Nothing left behind."
        case .straysKilled: "Drained. Strays were found and killed."
        case .straysSurvived: "Drained, but strays SURVIVED. Runners stay blocked until you acknowledge this."
        case nil: "Drain finished, but the reaper could not run. See the Logs page."
        }
        await refresh()
    }

    public func runSelfTest() async {
        guard !selfTestRunning else { return }
        selfTestRunning = true
        defer { selfTestRunning = false }

        selfTestProgress = "Starting…"
        let result = await store.services.selfTestService.run(config: store.config) { progress in
            Task { @MainActor in
                self.selfTestProgress = "\(progress.stage): \(progress.detail)"
            }
        }

        selfTestResult = result
        store.config.verification.lastProof = result
        store.markDirty()
        _ = await store.save()

        selfTestProgress = result.passed
            ? "PASS — run \(result.runId), \(result.durationSeconds)s"
            : "FAIL — run \(result.runId) concluded \(result.conclusion)"
    }
}
