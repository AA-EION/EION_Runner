import Foundation

public struct SelfTestProgress: Sendable {
    public let stage: String
    public let detail: String
}

/// The in-app self-test: one button that proves this setup currently works.
///
/// It dispatches the self-hosted self-test workflow, waits, downloads every
/// artifact, RE-ASSERTS the artifact contract locally rather than trusting the
/// CI job's word, runs the Reaper, and writes the result to
/// `verification.lastProof`.
///
/// The check that makes it meaningful is the runner-name check: a job that
/// silently landed on a GitHub-hosted runner proves nothing about YOUR runners.
public actor SelfTestService {
    private let logBus: LogBus
    private let configStore: ConfigStore
    private let actionsService: GitHubActionsService
    private let reaperService: ReaperService
    private let sweeperService: SweeperService
    private let processRunner: ProcessRunner

    public var workflowFile = "selftest-selfhosted.yml"
    public var gitRef = "main"
    public var projectName = "Canary"
    public var timeout: Duration = .seconds(90 * 60)

    public init(
        logBus: LogBus, configStore: ConfigStore, actionsService: GitHubActionsService,
        reaperService: ReaperService, sweeperService: SweeperService, processRunner: ProcessRunner
    ) {
        self.logBus = logBus
        self.configStore = configStore
        self.actionsService = actionsService
        self.reaperService = reaperService
        self.sweeperService = sweeperService
        self.processRunner = processRunner
    }

    public func run(
        config: ForgeConfig,
        onProgress: (@Sendable (SelfTestProgress) -> Void)? = nil
    ) async -> SelfTestResult {
        let started = Date()
        var result = SelfTestResult(startedAt: started)

        let repo = config.verification.canaryRepo.contains("/")
            ? String(config.verification.canaryRepo.split(separator: "/")[1])
            : (config.github.repos.first ?? "")

        do {
            // A unique tag echoed into run-name is how the run is identified.
            // Resolving "the newest run" is race-prone and wrong under concurrency.
            let tag = "rf-selftest-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"

            onProgress?(SelfTestProgress(stage: "Dispatching", detail: "\(workflowFile) with tag \(tag)"))

            let runId = try await actionsService.dispatchWorkflow(
                config: config, repo: repo, workflowFile: workflowFile, ref: gitRef,
                inputs: ["run_name_tag": tag, "project_name": projectName])

            result.runId = runId
            onProgress?(SelfTestProgress(stage: "Waiting", detail: "run \(runId)"))

            let conclusion = try await actionsService.waitForRun(
                config: config, repo: repo, runId: runId, timeout: timeout,
                onStatus: { message in onProgress?(SelfTestProgress(stage: "Waiting", detail: message)) })

            result.conclusion = conclusion
            result.durationSeconds = Int(Date().timeIntervalSince(started))

            // --- did it land on OUR runners? -----------------------------------
            onProgress?(SelfTestProgress(stage: "Checking runners", detail: "reading job runner names"))

            let jobs = try await actionsService.listJobs(config: config, repo: repo, runId: runId)
            result.runnerNames = jobs.map { $0.runnerName ?? "unknown" }

            for job in jobs {
                await logBus.info("selftest",
                    "  \(job.name): \(job.conclusion ?? "?") on \(job.runnerName ?? "unknown")")
            }

            if !result.allJobsOnForgeRunners {
                let offenders = jobs
                    .filter { !($0.runnerName ?? "").hasPrefix("forge-") }
                    .map { "\($0.name) (\($0.runnerName ?? "unknown"))" }
                    .joined(separator: ", ")
                await logBus.error("selftest",
                    "these jobs did not run on a Runner Forge runner: \(offenders). A job that landed on a "
                    + "hosted runner proves nothing about this setup.")
            }

            // --- artifacts -----------------------------------------------------
            onProgress?(SelfTestProgress(stage: "Downloading", detail: "artifacts"))

            let artifacts = try await actionsService.listArtifacts(
                config: config, repo: repo, runId: runId)

            let proofDir = (config.paths.workDir as NSString)
                .appendingPathComponent("proof/\(runId)")
            try FileManager.default.createDirectory(atPath: proofDir, withIntermediateDirectories: true)

            for artifact in artifacts {
                onProgress?(SelfTestProgress(stage: "Downloading", detail: artifact.name))
                _ = try await actionsService.downloadArtifact(
                    config: config, repo: repo, artifact: artifact,
                    destinationDirectory: proofDir, processRunner: processRunner)
            }

            // --- re-assert the contract LOCALLY --------------------------------
            onProgress?(SelfTestProgress(stage: "Verifying", detail: "re-asserting the artifact contract"))

            let aaxAvailable = !config.paths.aaxSdkSource.isEmpty
            let contract = ArtifactExpectation.contract(for: projectName, aaxAvailable: aaxAvailable)
            var contractSatisfied = true

            for expectation in contract {
                let outcome = await Self.verifyArtifact(
                    downloadRoot: proofDir, expectation: expectation, processRunner: processRunner)

                result.artifacts.append(SelfTestArtifact(
                    name: expectation.name, bytes: outcome.bytes,
                    fileCount: outcome.fileCount, verdict: outcome.passed ? "pass" : "fail"))

                if !outcome.passed && expectation.required {
                    contractSatisfied = false
                    await logBus.error("selftest", "artifact contract violated: \(expectation.name)")
                }
            }

            // --- reaper --------------------------------------------------------
            onProgress?(SelfTestProgress(stage: "Reaping", detail: "verifying nothing is still running"))
            let reaper = try await reaperService.reap(config: config)
            result.reaperExitCode = reaper.rawValue

            // --- sweeper -------------------------------------------------------
            onProgress?(SelfTestProgress(stage: "Sweeping", detail: "reclaiming ephemeral disk"))
            result.sweeperReclaimedBytes = Int(try await sweeperService.purge(config: config))

            // --- verdict -------------------------------------------------------
            let passed = conclusion == "success"
                && result.allJobsOnForgeRunners
                && contractSatisfied
                && reaper == .clean

            result.verdict = passed ? "pass" : "fail"
            result.durationSeconds = Int(Date().timeIntervalSince(started))

            await logBus.info("selftest", passed
                ? "SELF-TEST PASSED in \(result.durationSeconds)s (run \(runId))"
                : "SELF-TEST FAILED (run \(runId)): conclusion=\(conclusion), "
                  + "onForgeRunners=\(result.allJobsOnForgeRunners), contract=\(contractSatisfied), "
                  + "reaper=\(reaper)")
        } catch {
            result.verdict = "fail"
            await logBus.error("selftest", String(describing: error))
        }

        // Persisted so the Runners page can show, at a glance, whether this setup
        // is currently known-good.
        var updated = config
        updated.verification.lastProof = result
        try? await configStore.save(updated)

        return result
    }

    public struct ArtifactOutcome: Sendable {
        public let passed: Bool
        public let bytes: Int
        public let fileCount: Int
    }

    /// The in-app twin of scripts/verify-artifacts.sh. Untars macOS bundles
    /// before asserting, because upload-artifact flattens symlinks and the
    /// bundles are tarred on the way in specifically to survive that.
    public static func verifyArtifact(
        downloadRoot: String, expectation: ArtifactExpectation, processRunner: ProcessRunner
    ) async -> ArtifactOutcome {
        let directory = (downloadRoot as NSString).appendingPathComponent(expectation.name)

        guard FileManager.default.fileExists(atPath: directory) else {
            return ArtifactOutcome(passed: !expectation.required, bytes: 0, fileCount: 0)
        }

        let files = allFiles(under: directory)
        let bytes = files.reduce(0) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
        }

        guard bytes > 0 else {
            return ArtifactOutcome(passed: false, bytes: 0, fileCount: files.count)
        }

        var searchRoot = directory

        if expectation.untar {
            let extracted = (directory as NSString).appendingPathComponent("__untarred")
            try? FileManager.default.createDirectory(atPath: extracted, withIntermediateDirectories: true)

            let tarballs = files.filter { $0.hasSuffix(".tar") }
            guard !tarballs.isEmpty else {
                return ArtifactOutcome(passed: false, bytes: bytes, fileCount: files.count)
            }

            for tarball in tarballs {
                // -p preserves permissions and restores the symlinks that
                // upload-artifact would otherwise have flattened.
                _ = try? await processRunner.run(
                    "/usr/bin/tar", arguments: ["-xpf", tarball, "-C", extracted],
                    logSource: "selftest", streamOutput: false)
            }

            searchRoot = extracted
        }

        for glob in expectation.globs {
            let matches = entries(under: searchRoot, matching: glob)
            guard !matches.isEmpty else {
                return ArtifactOutcome(passed: false, bytes: bytes, fileCount: files.count)
            }

            let anyNonEmpty = matches.contains { match in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: match, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    return allFiles(under: match).contains { path in
                        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                        return ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 0
                    }
                }
                let attributes = try? FileManager.default.attributesOfItem(atPath: match)
                return ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 0
            }

            guard anyNonEmpty else {
                return ArtifactOutcome(passed: false, bytes: bytes, fileCount: files.count)
            }
        }

        for bundleGlob in expectation.bundles {
            for bundle in entries(under: searchRoot, matching: bundleGlob) {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: bundle, isDirectory: &isDirectory)
                guard isDirectory.boolValue else { continue }

                let macOsDir = (bundle as NSString).appendingPathComponent("Contents/MacOS")
                let plist = (bundle as NSString).appendingPathComponent("Contents/Info.plist")

                guard FileManager.default.fileExists(atPath: macOsDir),
                      FileManager.default.fileExists(atPath: plist) else {
                    return ArtifactOutcome(passed: false, bytes: bytes, fileCount: files.count)
                }
            }
        }

        return ArtifactOutcome(passed: true, bytes: bytes, fileCount: files.count)
    }

    static func allFiles(under directory: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        var result: [String] = []

        while let relative = enumerator.nextObject() as? String {
            let full = (directory as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory)
            if !isDirectory.boolValue { result.append(full) }
        }

        return result
    }

    static func entries(under directory: String, matching glob: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        var result: [String] = []

        // The globs in the contract are simple "*.ext" or a literal file name.
        let suffix = glob.hasPrefix("*") ? String(glob.dropFirst()) : nil

        while let relative = enumerator.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            let matches = suffix.map { name.hasSuffix($0) } ?? (name == glob)
            if matches { result.append((directory as NSString).appendingPathComponent(relative)) }
        }

        return result
    }
}
