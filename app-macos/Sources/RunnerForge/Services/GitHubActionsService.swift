import Foundation

public struct WorkflowArtifact: Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let sizeInBytes: Int
    public let expired: Bool
    public let archiveDownloadUrl: String
}

public struct WorkflowJobInfo: Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let status: String
    public let conclusion: String?
    public let runnerName: String?
}

/// Dispatches workflows, waits for them, and pulls their artifacts back down.
/// This is what makes the in-app self-test possible.
public actor GitHubActionsService {
    private let logBus: LogBus
    private let appService: GitHubAppService
    private let session: URLSession

    public var apiBaseUrl = "https://api.github.com"
    public var pollInterval: Duration = .seconds(15)

    public init(logBus: LogBus, appService: GitHubAppService, session: URLSession = .shared) {
        self.logBus = logBus
        self.appService = appService
        self.session = session
    }

    /// Dispatches a workflow and resolves the run it created.
    ///
    /// The run is found by matching a unique tag echoed into the workflow's
    /// `run-name`. Taking "the newest run" is race-prone and simply wrong under
    /// concurrency: two dispatches seconds apart would both resolve to whichever
    /// appeared first.
    public func dispatchWorkflow(
        config: ForgeConfig,
        repo: String,
        workflowFile: String,
        ref: String,
        inputs: [String: String]
    ) async throws -> Int {
        guard let tag = inputs["run_name_tag"], !tag.isEmpty else {
            throw GitHubError.malformedResponse(
                "inputs must contain a unique 'run_name_tag'. Without it the dispatched run cannot be "
                + "identified reliably, and resolving 'the newest run' is wrong under concurrency.")
        }

        let token = try await appService.installationToken(config: config)
        let payload: [String: Any] = ["ref": ref, "inputs": inputs]

        let (data, response) = try await appService.send(
            path: "/repos/\(config.github.owner)/\(repo)/actions/workflows/\(workflowFile)/dispatches",
            method: "POST", token: token,
            body: try JSONSerialization.data(withJSONObject: payload))

        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.api(status: response.statusCode,
                                  body: String(decoding: data, as: UTF8.self),
                                  operation: "dispatch \(workflowFile)")
        }

        await logBus.info("actions", "dispatched \(workflowFile) on \(ref) with tag \(tag)")

        // GitHub takes a moment to index the new run.
        for _ in 1...30 {
            let runs = try await getJson(
                config: config,
                path: "/repos/\(config.github.owner)/\(repo)/actions/runs?event=workflow_dispatch&per_page=30")

            if let list = runs["workflow_runs"] as? [[String: Any]] {
                for run in list {
                    guard let name = run["name"] as? String, name.contains(tag),
                          let id = run["id"] as? Int else { continue }
                    await logBus.info("actions", "resolved the dispatched run by its tag: \(id)")
                    return id
                }
            }

            try? await Task.sleep(for: .seconds(4))
        }

        throw GitHubError.malformedResponse(
            "The workflow was dispatched but no run carrying the tag '\(tag)' appeared within two "
            + "minutes. Check that the workflow echoes run_name_tag into its run-name.")
    }

    /// Polls until the run completes. Returns success, failure, cancelled or
    /// timed_out.
    public func waitForRun(
        config: ForgeConfig,
        repo: String,
        runId: Int,
        timeout: Duration,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
        var lastStatus = ""

        while Date() < deadline {
            let run = try await getJson(
                config: config, path: "/repos/\(config.github.owner)/\(repo)/actions/runs/\(runId)")

            let status = run["status"] as? String ?? "unknown"
            let conclusion = run["conclusion"] as? String

            if status != lastStatus {
                await logBus.info("actions", "run \(runId): \(status)")
                onStatus?("run \(runId): \(status)")
                lastStatus = status
            }

            if status == "completed" {
                await logBus.info("actions", "run \(runId) concluded: \(conclusion ?? "unknown")")
                return conclusion ?? "failure"
            }

            try? await Task.sleep(for: pollInterval)
        }

        await logBus.error("actions", "run \(runId) did not finish within the timeout")
        return "timed_out"
    }

    public func listJobs(config: ForgeConfig, repo: String, runId: Int) async throws -> [WorkflowJobInfo] {
        let json = try await getJson(
            config: config,
            path: "/repos/\(config.github.owner)/\(repo)/actions/runs/\(runId)/jobs?per_page=100")

        guard let jobs = json["jobs"] as? [[String: Any]] else { return [] }

        return jobs.map { job in
            WorkflowJobInfo(
                id: job["id"] as? Int ?? 0,
                name: job["name"] as? String ?? "",
                status: job["status"] as? String ?? "",
                conclusion: job["conclusion"] as? String,
                runnerName: job["runner_name"] as? String)
        }
    }

    public func listArtifacts(config: ForgeConfig, repo: String, runId: Int) async throws -> [WorkflowArtifact] {
        let json = try await getJson(
            config: config,
            path: "/repos/\(config.github.owner)/\(repo)/actions/runs/\(runId)/artifacts?per_page=100")

        guard let artifacts = json["artifacts"] as? [[String: Any]] else { return [] }

        return artifacts.map { artifact in
            WorkflowArtifact(
                id: artifact["id"] as? Int ?? 0,
                name: artifact["name"] as? String ?? "",
                sizeInBytes: artifact["size_in_bytes"] as? Int ?? 0,
                expired: artifact["expired"] as? Bool ?? false,
                archiveDownloadUrl: artifact["archive_download_url"] as? String ?? "")
        }
    }

    /// Downloads an artifact, unzips it, and returns the extracted files.
    @discardableResult
    public func downloadArtifact(
        config: ForgeConfig,
        repo: String,
        artifact: WorkflowArtifact,
        destinationDirectory: String,
        processRunner: ProcessRunner
    ) async throws -> [String] {
        let token = try await appService.installationToken(config: config)

        var request = URLRequest(url: URL(
            string: "\(apiBaseUrl)/repos/\(config.github.owner)/\(repo)/actions/artifacts/\(artifact.id)/zip")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RunnerForge/1.0", forHTTPHeaderField: "User-Agent")

        let (temporaryUrl, response) = try await session.download(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GitHubError.malformedResponse("downloading artifact '\(artifact.name)' failed")
        }

        let extractTo = (destinationDirectory as NSString).appendingPathComponent(artifact.name)
        try FileManager.default.createDirectory(atPath: extractTo, withIntermediateDirectories: true)

        let zipPath = (destinationDirectory as NSString).appendingPathComponent("\(artifact.name).zip")
        try? FileManager.default.removeItem(atPath: zipPath)
        try FileManager.default.moveItem(at: temporaryUrl, to: URL(fileURLWithPath: zipPath))

        _ = try await processRunner.run(
            "/usr/bin/unzip", arguments: ["-qo", zipPath, "-d", extractTo],
            logSource: "actions", streamOutput: false)

        try? FileManager.default.removeItem(atPath: zipPath)

        let files = FileManager.default.enumerator(atPath: extractTo)?
            .compactMap { $0 as? String }
            .map { (extractTo as NSString).appendingPathComponent($0) } ?? []

        await logBus.info("actions",
            "downloaded \(artifact.name): \(files.count) entr(ies), \(artifact.sizeInBytes) bytes")

        return files
    }

    /// Self-hosted runners registered on the repository. Used by crash recovery.
    public func listSelfHostedRunners(
        config: ForgeConfig, repo: String
    ) async throws -> [(id: Int, name: String, status: String)] {
        let json = try await getJson(
            config: config, path: "/repos/\(config.github.owner)/\(repo)/actions/runners?per_page=100")

        guard let runners = json["runners"] as? [[String: Any]] else { return [] }

        return runners.map {
            (id: $0["id"] as? Int ?? 0,
             name: $0["name"] as? String ?? "",
             status: $0["status"] as? String ?? "")
        }
    }

    /// Removes a dangling registration left behind by a crash.
    @discardableResult
    public func deleteRunner(config: ForgeConfig, repo: String, runnerId: Int) async throws -> Bool {
        let token = try await appService.installationToken(config: config)
        let (_, response) = try await appService.send(
            path: "/repos/\(config.github.owner)/\(repo)/actions/runners/\(runnerId)",
            method: "DELETE", token: token, body: nil)

        let ok = (200..<300).contains(response.statusCode)
        await logBus.info("actions", ok
            ? "removed offline runner registration \(runnerId)"
            : "could not remove runner \(runnerId): \(response.statusCode)")
        return ok
    }

    private func getJson(config: ForgeConfig, path: String) async throws -> [String: Any] {
        let token = try await appService.installationToken(config: config)
        let (data, response) = try await appService.send(
            path: path, method: "GET", token: token, body: nil)

        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.api(status: response.statusCode,
                                  body: String(decoding: data, as: UTF8.self),
                                  operation: "GET \(path)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.malformedResponse("GET \(path) returned no JSON object")
        }

        return json
    }
}
