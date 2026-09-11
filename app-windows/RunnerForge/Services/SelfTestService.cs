using System.Formats.Tar;
using System.IO.Compression;
using RunnerForge.Models;

namespace RunnerForge.Services;

public sealed record SelfTestProgress(string Stage, string Detail);

/// <summary>
/// The in-app self-test: one button that proves this setup currently works.
/// </summary>
/// <remarks>
/// It dispatches the self-hosted self-test workflow, waits, downloads every
/// artifact, RE-ASSERTS the artifact contract locally rather than trusting the
/// CI job's word, runs the Reaper, and writes the result to
/// <c>verification.lastProof</c>.
///
/// The check that makes it meaningful is the runner-name check: a job that
/// silently landed on a GitHub-hosted runner proves nothing about YOUR runners.
/// </remarks>
public sealed class SelfTestService(
    LogBus logBus,
    ConfigStore configStore,
    GitHubActionsService actionsService,
    ReaperService reaperService,
    SweeperService sweeperService)
{
    private readonly LogBus _logBus = logBus;
    private readonly ConfigStore _configStore = configStore;
    private readonly GitHubActionsService _actionsService = actionsService;
    private readonly ReaperService _reaperService = reaperService;
    private readonly SweeperService _sweeperService = sweeperService;

    public string WorkflowFile { get; set; } = "selftest-selfhosted.yml";
    public string GitRef { get; set; } = "main";
    public string ProjectName { get; set; } = "Canary";
    public TimeSpan Timeout { get; set; } = TimeSpan.FromMinutes(90);

    public async Task<SelfTestResult> RunAsync(
        ForgeConfig config,
        IProgress<SelfTestProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        DateTimeOffset started = DateTimeOffset.UtcNow;
        string repo = config.Verification.CanaryRepo.Contains('/')
            ? config.Verification.CanaryRepo.Split('/')[1]
            : config.GitHub.Repos.FirstOrDefault() ?? "";

        var result = new SelfTestResult { StartedAt = started, Conclusion = "failure", Verdict = "fail" };

        try
        {
            // A unique tag echoed into run-name is how the run is identified.
            // Resolving "the newest run" is race-prone and wrong under concurrency.
            string tag = $"rf-selftest-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}-{Guid.NewGuid():N}"[..48];

            progress?.Report(new SelfTestProgress("Dispatching", $"{WorkflowFile} with tag {tag}"));

            long runId = await _actionsService.DispatchWorkflowAsync(
                config, repo, WorkflowFile, GitRef,
                new Dictionary<string, string> { ["run_name_tag"] = tag, ["project_name"] = ProjectName },
                cancellationToken).ConfigureAwait(false);

            result.RunId = runId;
            progress?.Report(new SelfTestProgress("Waiting", $"run {runId}"));

            var runProgress = new Progress<string>(message =>
                progress?.Report(new SelfTestProgress("Waiting", message)));

            string conclusion = await _actionsService
                .WaitForRunAsync(config, repo, runId, Timeout, runProgress, cancellationToken)
                .ConfigureAwait(false);

            result.Conclusion = conclusion;
            result.DurationSeconds = (int)(DateTimeOffset.UtcNow - started).TotalSeconds;

            // --- did it land on OUR runners? -------------------------------
            progress?.Report(new SelfTestProgress("Checking runners", "reading job runner names"));

            IReadOnlyList<WorkflowJobInfo> jobs = await _actionsService
                .ListJobsAsync(config, repo, runId, cancellationToken).ConfigureAwait(false);

            result.RunnerNames = [.. jobs.Select(j => j.RunnerName ?? "unknown")];

            foreach (WorkflowJobInfo job in jobs)
            {
                _logBus.Info("selftest", $"  {job.Name}: {job.Conclusion} on {job.RunnerName ?? "unknown"}");
            }

            if (!result.AllJobsOnForgeRunners)
            {
                string offenders = string.Join(", ",
                    jobs.Where(j => !(j.RunnerName ?? "").StartsWith("forge-", StringComparison.Ordinal))
                        .Select(j => $"{j.Name} ({j.RunnerName ?? "unknown"})"));
                _logBus.Error("selftest",
                    $"these jobs did not run on a Runner Forge runner: {offenders}. "
                    + "A job that landed on a hosted runner proves nothing about this setup.");
            }

            // --- artifacts -------------------------------------------------
            progress?.Report(new SelfTestProgress("Downloading", "artifacts"));

            IReadOnlyList<WorkflowArtifact> artifacts = await _actionsService
                .ListArtifactsAsync(config, repo, runId, cancellationToken).ConfigureAwait(false);

            string proofDir = Path.Combine(config.Paths.WorkDir, "proof", runId.ToString());
            Directory.CreateDirectory(proofDir);

            foreach (WorkflowArtifact artifact in artifacts)
            {
                progress?.Report(new SelfTestProgress("Downloading", artifact.Name));
                await _actionsService
                    .DownloadArtifactAsync(config, repo, artifact, proofDir, cancellationToken)
                    .ConfigureAwait(false);
            }

            // --- re-assert the contract LOCALLY ----------------------------
            progress?.Report(new SelfTestProgress("Verifying", "re-asserting the artifact contract"));

            bool aaxAvailable = !string.IsNullOrWhiteSpace(config.Paths.AaxSdkSource);
            IReadOnlyList<ArtifactExpectation> contract =
                ArtifactExpectation.ContractFor(ProjectName, aaxAvailable);

            bool contractSatisfied = true;

            foreach (ArtifactExpectation expectation in contract)
            {
                (bool artifactOk, long bytes, int files) = VerifyArtifact(proofDir, expectation);

                result.Artifacts.Add(new SelfTestArtifact
                {
                    Name = expectation.Name,
                    Bytes = bytes,
                    FileCount = files,
                    Verdict = artifactOk ? "pass" : "fail",
                });

                if (!artifactOk && expectation.Required)
                {
                    contractSatisfied = false;
                    _logBus.Error("selftest", $"artifact contract violated: {expectation.Name}");
                }
            }

            // --- reaper ----------------------------------------------------
            progress?.Report(new SelfTestProgress("Reaping", "verifying nothing is still running"));

            ReaperResult reaper = await _reaperService
                .ReapAsync(config, [], [], cancellationToken).ConfigureAwait(false);
            result.ReaperExitCode = (int)reaper;

            // --- sweeper ---------------------------------------------------
            progress?.Report(new SelfTestProgress("Sweeping", "reclaiming ephemeral disk"));
            result.SweeperReclaimedBytes = await _sweeperService
                .PurgeAsync(config, cancellationToken).ConfigureAwait(false);

            // --- verdict ---------------------------------------------------
            bool passed = conclusion == "success"
                          && result.AllJobsOnForgeRunners
                          && contractSatisfied
                          && reaper == ReaperResult.Clean;

            result.Verdict = passed ? "pass" : "fail";
            result.DurationSeconds = (int)(DateTimeOffset.UtcNow - started).TotalSeconds;

            _logBus.Info("selftest", passed
                ? $"SELF-TEST PASSED in {result.DurationSeconds}s (run {runId})"
                : $"SELF-TEST FAILED (run {runId}): conclusion={conclusion}, "
                  + $"onForgeRunners={result.AllJobsOnForgeRunners}, contract={contractSatisfied}, "
                  + $"reaper={reaper}");
        }
        catch (OperationCanceledException)
        {
            result.Conclusion = "cancelled";
            result.Verdict = "fail";
            _logBus.Warning("selftest", "cancelled");
        }
        catch (Exception ex)
        {
            result.Verdict = "fail";
            _logBus.Error("selftest", ex.Message);
        }

        // Persisted so the Runners page can show, at a glance, whether this
        // setup is currently known-good.
        config.Verification.LastProof = result;
        _configStore.Save(config);

        return result;
    }

    /// <summary>
    /// The in-app twin of scripts/verify-artifacts.sh. Untars macOS bundles
    /// before asserting, because upload-artifact flattens symlinks and the
    /// bundles are tarred on the way in specifically to survive that.
    /// </summary>
    public static (bool Passed, long Bytes, int FileCount) VerifyArtifact(
        string downloadRoot, ArtifactExpectation expectation)
    {
        string directory = Path.Combine(downloadRoot, expectation.Name);

        if (!Directory.Exists(directory))
        {
            return (!expectation.Required, 0, 0);
        }

        string[] files = Directory.GetFiles(directory, "*", SearchOption.AllDirectories);
        long bytes = files.Sum(f => new FileInfo(f).Length);

        if (bytes == 0) return (false, 0, files.Length);

        string searchRoot = directory;

        if (expectation.Untar)
        {
            string extracted = Path.Combine(directory, "__untarred");
            Directory.CreateDirectory(extracted);

            string[] tarballs = Directory.GetFiles(directory, "*.tar", SearchOption.AllDirectories);
            if (tarballs.Length == 0) return (false, bytes, files.Length);

            foreach (string tarball in tarballs)
            {
                try { TarFile.ExtractToDirectory(tarball, extracted, overwriteFiles: true); }
                catch (Exception) { return (false, bytes, files.Length); }
            }

            searchRoot = extracted;
        }

        foreach (string glob in expectation.Globs)
        {
            string[] matches = Directory.GetFileSystemEntries(searchRoot, glob, SearchOption.AllDirectories);
            if (matches.Length == 0) return (false, bytes, files.Length);

            bool anyNonEmpty = matches.Any(m =>
                Directory.Exists(m)
                    ? Directory.GetFiles(m, "*", SearchOption.AllDirectories).Any(f => new FileInfo(f).Length > 0)
                    : new FileInfo(m).Length > 0);

            if (!anyNonEmpty) return (false, bytes, files.Length);
        }

        foreach (string bundleGlob in expectation.Bundles)
        {
            foreach (string bundle in Directory.GetDirectories(searchRoot, bundleGlob, SearchOption.AllDirectories))
            {
                if (!Directory.Exists(Path.Combine(bundle, "Contents", "MacOS"))) return (false, bytes, files.Length);
                if (!File.Exists(Path.Combine(bundle, "Contents", "Info.plist"))) return (false, bytes, files.Length);
            }
        }

        return (true, bytes, files.Length);
    }
}
