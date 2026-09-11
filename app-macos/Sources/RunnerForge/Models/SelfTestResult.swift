import Foundation

/// The record of one in-app self-test, persisted to `verification.lastProof` so
/// the Runners page can show at a glance whether this setup is known-good.
public struct SelfTestResult: Codable, Sendable, Equatable {
    public var runId: Int
    public var startedAt: Date
    public var durationSeconds: Int

    /// success, failure, cancelled or timed_out.
    public var conclusion: String
    public var artifacts: [SelfTestArtifact]

    /// The runner each job landed on. These must all start with "forge-": a job
    /// that silently ran on a hosted runner proves nothing about this setup.
    public var runnerNames: [String]

    /// 0 clean, 10 strays killed, 20 strays survived.
    public var reaperExitCode: Int
    public var sweeperReclaimedBytes: Int

    /// pass or fail.
    public var verdict: String

    public var passed: Bool { verdict == "pass" }

    /// True when every job ran on a Runner Forge runner. Checked explicitly
    /// because it is the one thing that makes a self-hosted result meaningful.
    public var allJobsOnForgeRunners: Bool {
        !runnerNames.isEmpty && runnerNames.allSatisfy { $0.hasPrefix("forge-") }
    }

    public init(
        runId: Int = 0,
        startedAt: Date = Date(),
        durationSeconds: Int = 0,
        conclusion: String = "failure",
        artifacts: [SelfTestArtifact] = [],
        runnerNames: [String] = [],
        reaperExitCode: Int = 0,
        sweeperReclaimedBytes: Int = 0,
        verdict: String = "fail"
    ) {
        self.runId = runId
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.conclusion = conclusion
        self.artifacts = artifacts
        self.runnerNames = runnerNames
        self.reaperExitCode = reaperExitCode
        self.sweeperReclaimedBytes = sweeperReclaimedBytes
        self.verdict = verdict
    }
}

public struct SelfTestArtifact: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var bytes: Int
    public var fileCount: Int

    /// pass or fail.
    public var verdict: String

    public var id: String { name }

    public init(name: String, bytes: Int, fileCount: Int, verdict: String) {
        self.name = name
        self.bytes = bytes
        self.fileCount = fileCount
        self.verdict = verdict
    }
}
