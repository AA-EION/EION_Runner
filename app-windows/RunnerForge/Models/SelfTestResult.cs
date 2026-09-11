using System.Text.Json.Serialization;

namespace RunnerForge.Models;

/// <summary>
/// The record of one in-app self-test, persisted to
/// <c>verification.lastProof</c> so the Runners page can show at a glance
/// whether this setup is currently known-good.
/// </summary>
public sealed class SelfTestResult
{
    [JsonPropertyName("runId")] public long RunId { get; set; }

    [JsonPropertyName("startedAt")] public DateTimeOffset StartedAt { get; set; }

    [JsonPropertyName("durationSeconds")] public int DurationSeconds { get; set; }

    /// <summary>success, failure, cancelled or timed_out.</summary>
    [JsonPropertyName("conclusion")] public string Conclusion { get; set; } = "";

    [JsonPropertyName("artifacts")] public List<SelfTestArtifact> Artifacts { get; set; } = [];

    /// <summary>
    /// The runner each job landed on. These must all start with "forge-": a job
    /// that silently ran on a hosted runner proves nothing about this setup.
    /// </summary>
    [JsonPropertyName("runnerNames")] public List<string> RunnerNames { get; set; } = [];

    /// <summary>0 clean, 10 strays killed, 20 strays survived.</summary>
    [JsonPropertyName("reaperExitCode")] public int ReaperExitCode { get; set; }

    [JsonPropertyName("sweeperReclaimedBytes")] public long SweeperReclaimedBytes { get; set; }

    /// <summary>pass or fail.</summary>
    [JsonPropertyName("verdict")] public string Verdict { get; set; } = "fail";

    [JsonIgnore] public bool Passed => Verdict == "pass";

    /// <summary>
    /// True when every job ran on a Runner Forge runner. Checked explicitly
    /// because it is the one thing that makes a self-hosted result meaningful.
    /// </summary>
    [JsonIgnore]
    public bool AllJobsOnForgeRunners =>
        RunnerNames.Count > 0 && RunnerNames.All(n => n.StartsWith("forge-", StringComparison.Ordinal));
}

public sealed class SelfTestArtifact
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("bytes")] public long Bytes { get; set; }
    [JsonPropertyName("fileCount")] public int FileCount { get; set; }

    /// <summary>pass or fail.</summary>
    [JsonPropertyName("verdict")] public string Verdict { get; set; } = "fail";
}
