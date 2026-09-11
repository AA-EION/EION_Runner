import Foundation

public enum ReplicaState: String, Sendable {
    case stopped, starting, waitingForJob, runningJob, cleaningUp, error

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .waitingForJob: "Waiting for job"
        case .runningJob: "Running job"
        case .cleaningUp: "Cleaning up"
        case .error: "Error"
        }
    }
}

public struct ReplicaStatus: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public var classId: String
    public var index: Int
    public var runnerName: String = ""
    public var state: ReplicaState = .stopped
    public var startedAt: Date?
    public var jobsCompletedToday: Int = 0
    public var lastError: String?
}

/// Crash-safe record of what was running, written before launch.
struct SupervisorState: Codable {
    var runners: [SupervisorRunnerEntry] = []
}

struct SupervisorRunnerEntry: Codable {
    var runnerName: String
    var classId: String
    var pid: Int32?
    var startedAt: Date
    var repo: String
}

/// Starts, watches and replaces ephemeral runners.
///
/// Every runner takes ONE job and dies. State is written to
/// `paths.workDir/state.json` BEFORE a process is launched, so a hard power cut
/// leaves a record the next launch can clean up rather than an orphan nobody
/// knows about.
public actor RunnerSupervisor {
    private let logBus: LogBus
    private let tartService: TartService
    private let appService: GitHubAppService
    private let actionsService: GitHubActionsService
    private let reaperService: ReaperService

    private var replicas: [String: ReplicaStatus] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var recentFailures: [String: [Date]] = [:]

    /// Three non-zero exits within five minutes stops the class. A broken class —
    /// bad image, wrong labels, revoked key — must never hot-loop against the
    /// GitHub API.
    public static let failureThreshold = 3
    public static let failureWindow: TimeInterval = 300

    /// Set when the Reaper reported survivors. Blocks new runners until acknowledged.
    public private(set) var blockedByStraySurvivors = false
    public private(set) var straySurvivorDetails: [String] = []

    public var scriptsDirectory: String = "/usr/local/share/runnerforge/scripts"

    public init(
        logBus: LogBus, tartService: TartService, appService: GitHubAppService,
        actionsService: GitHubActionsService, reaperService: ReaperService
    ) {
        self.logBus = logBus
        self.tartService = tartService
        self.appService = appService
        self.actionsService = actionsService
        self.reaperService = reaperService
    }

    public func currentReplicas() -> [ReplicaStatus] {
        replicas.values.sorted { ($0.classId, $0.index) < ($1.classId, $1.index) }
    }

    public func acknowledgeStraySurvivors() {
        blockedByStraySurvivors = false
        straySurvivorDetails = []
    }

    private func key(_ classId: String, _ index: Int) -> String { "\(classId)#\(index)" }

    public func startClass(config: ForgeConfig, runnerClass: RunnerClass) async {
        guard !blockedByStraySurvivors else {
            await logBus.error("supervisor",
                "refusing to start runners: the Reaper reported survivors that must be acknowledged first.")
            return
        }

        guard runnerClass.runsOnMac else {
            // Windows classes run on the PC. This app never virtualizes Windows
            // containers, and saying so beats a button that silently does nothing.
            await logBus.warning("supervisor",
                "\(runnerClass.classId) runs on the Windows host, not on this Mac.")
            return
        }

        guard let runnerConfig = config.runners.first(where: { $0.classId == runnerClass.classId }),
              runnerConfig.enabled else {
            await logBus.warning("supervisor", "\(runnerClass.classId) is not enabled")
            return
        }

        let count = runnerClass.replicasAreFixed ? 1 : runnerConfig.replicas

        for index in 0..<count {
            let replicaKey = key(runnerClass.classId, index)
            if let existing = replicas[replicaKey], existing.state != .stopped, existing.state != .error {
                continue
            }

            replicas[replicaKey] = ReplicaStatus(classId: runnerClass.classId, index: index)

            tasks[replicaKey] = Task { [weak self] in
                await self?.runReplicaLoop(config: config, runnerClass: runnerClass, key: replicaKey)
            }
        }
    }

    /// One replica's whole life: mint a JIT config, run one job, reap, replace.
    private func runReplicaLoop(config: ForgeConfig, runnerClass: RunnerClass, key replicaKey: String) async {
        let repo = config.github.repos.first ?? ""

        while !Task.isCancelled {
            if isBackingOff(runnerClass.classId) {
                replicas[replicaKey]?.state = .error
                replicas[replicaKey]?.lastError =
                    "stopped after \(Self.failureThreshold) failures within 5 minutes"
                await logBus.error("supervisor",
                    "\(runnerClass.classId): stopped after repeated failures. Not retrying — a broken class "
                    + "must not hot-loop.")
                return
            }

            do {
                replicas[replicaKey]?.state = .starting

                let jit = try await appService.generateJitConfig(
                    config: config, repo: repo, runnerClass: runnerClass)

                replicas[replicaKey]?.runnerName = jit.runnerName
                replicas[replicaKey]?.startedAt = Date()
                replicas[replicaKey]?.state = .waitingForJob

                // Recorded BEFORE launch: a crash between here and exit leaves a
                // record the next start can reap.
                recordState(config: config, entry: SupervisorRunnerEntry(
                    runnerName: jit.runnerName, classId: runnerClass.classId,
                    pid: nil, startedAt: Date(), repo: repo))

                let timeout = config.runners
                    .first { $0.classId == runnerClass.classId }?.jobTimeoutMinutes ?? 90

                let result = try await tartService.runEphemeralJob(
                    scriptsDirectory: scriptsDirectory,
                    image: "runnerforge-macos:1.0.0",
                    jitConfig: jit.encodedConfig,
                    cacheDirectory: (config.paths.workDir as NSString).appendingPathComponent("cache"),
                    jobTimeoutMinutes: timeout)

                replicas[replicaKey]?.state = .cleaningUp
                forgetState(config: config, runnerName: jit.runnerName)

                if result.succeeded {
                    replicas[replicaKey]?.jobsCompletedToday += 1
                    recentFailures[runnerClass.classId] = []
                } else {
                    recordFailure(runnerClass.classId)
                    replicas[replicaKey]?.lastError = "exit code \(result.exitCode)"
                    await logBus.warning("supervisor",
                        "\(jit.runnerName) exited with \(result.exitCode)")
                }

                await reapScoped(config: config)
            } catch is CancellationError {
                break
            } catch {
                recordFailure(runnerClass.classId)
                replicas[replicaKey]?.state = .error
                replicas[replicaKey]?.lastError = String(describing: error)
                await logBus.error("supervisor", String(describing: error))
                try? await Task.sleep(for: .seconds(5))
            }
        }

        replicas[replicaKey]?.state = .stopped
        replicas[replicaKey]?.startedAt = nil
    }

    private func reapScoped(config: ForgeConfig) async {
        let liveNames = Set(replicas.values
            .filter { $0.state == .runningJob || $0.state == .waitingForJob }
            .map(\.runnerName)
            .filter { !$0.isEmpty })

        guard let result = try? await reaperService.reap(
            config: config, livePids: [], liveRunnerNames: liveNames) else { return }

        if result == .straysSurvived {
            blockedByStraySurvivors = true
            let survivors = (try? await reaperService.findStrays(
                config: config, livePids: [], liveRunnerNames: liveNames)) ?? []
            straySurvivorDetails = survivors.map(\.detail)
        }
    }

    public func stopClass(_ runnerClass: RunnerClass) {
        for (replicaKey, task) in tasks where replicaKey.hasPrefix(runnerClass.classId + "#") {
            task.cancel()
            tasks[replicaKey] = nil
        }
    }

    /// Refuses new jobs and waits for in-flight ones, then forces. Called on app
    /// close, so the user never loses a running build to a window close.
    public func drain(timeout: TimeInterval, onProgress: (@Sendable (String) -> Void)? = nil) async {
        onProgress?("refusing new jobs")
        for task in tasks.values { task.cancel() }

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let inFlight = replicas.values.count { $0.state == .runningJob }
            if inFlight == 0 { break }
            onProgress?("waiting for \(inFlight) in-flight job(s)")
            try? await Task.sleep(for: .seconds(2))
        }

        onProgress?("drained")
    }

    /// On start, reap anything recorded but not alive, and remove any offline
    /// forge-* registration left dangling on GitHub by a crash.
    public func recoverFromCrash(config: ForgeConfig) async {
        let state = readState(config: config)

        if !state.runners.isEmpty {
            await logBus.warning("supervisor",
                "state.json records \(state.runners.count) runner(s) from a previous session; reaping")
            _ = try? await reaperService.reap(config: config)
            writeState(config: config, state: SupervisorState())
        }

        for repo in config.github.repos {
            guard let runners = try? await actionsService.listSelfHostedRunners(
                config: config, repo: repo) else { continue }

            for runner in runners where runner.name.hasPrefix("forge-") && runner.status == "offline" {
                await logBus.info("supervisor", "removing offline registration \(runner.name) from \(repo)")
                _ = try? await actionsService.deleteRunner(config: config, repo: repo, runnerId: runner.id)
            }
        }
    }

    // --- backoff -------------------------------------------------------------
    private func isBackingOff(_ classId: String) -> Bool {
        guard var failures = recentFailures[classId] else { return false }
        failures.removeAll { Date().timeIntervalSince($0) > Self.failureWindow }
        recentFailures[classId] = failures
        return failures.count >= Self.failureThreshold
    }

    private func recordFailure(_ classId: String) {
        recentFailures[classId, default: []].append(Date())
    }

    // --- crash-safe state ----------------------------------------------------
    private func statePath(config: ForgeConfig) -> String {
        (config.paths.workDir as NSString).appendingPathComponent("state.json")
    }

    private func readState(config: ForgeConfig) -> SupervisorState {
        let path = statePath(config: config)
        guard let data = FileManager.default.contents(atPath: path),
              let state = try? JSONDecoder().decode(SupervisorState.self, from: data) else {
            return SupervisorState()
        }
        return state
    }

    private func writeState(config: ForgeConfig, state: SupervisorState) {
        try? FileManager.default.createDirectory(
            atPath: config.paths.workDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath(config: config)))
    }

    private func recordState(config: ForgeConfig, entry: SupervisorRunnerEntry) {
        var state = readState(config: config)
        state.runners.append(entry)
        writeState(config: config, state: state)
    }

    private func forgetState(config: ForgeConfig, runnerName: String) {
        var state = readState(config: config)
        state.runners.removeAll { $0.runnerName == runnerName }
        writeState(config: config, state: state)
    }
}
