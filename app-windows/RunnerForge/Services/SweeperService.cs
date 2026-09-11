using RunnerForge.Models;

namespace RunnerForge.Services;

/// <summary>
/// "Clean on close, keep only what makes the next run fast."
/// </summary>
/// <remarks>
/// The policy lives in <see cref="SweeperPolicy"/> as pure, testable logic so it
/// can be proven without touching a disk. The rule that matters most:
/// <c>docker system prune -a</c> is NEVER used — it would delete the tagged base
/// images, which is exactly what the KEEP list exists to prevent.
/// </remarks>
public sealed class SweeperService(LogBus logBus, ProcessRunner processRunner)
{
    private readonly LogBus _logBus = logBus;
    private readonly ProcessRunner _processRunner = processRunner;

    public async Task<DiskUsage> SurveyAsync(ForgeConfig config, CancellationToken cancellationToken = default)
    {
        var keep = new List<DiskUsageItem>();
        var purge = new List<DiskUsageItem>();
        string workDir = config.Paths.WorkDir;

        foreach (string volume in SweeperPolicy.KeepVolumes)
        {
            ProcessResult inspect = await _processRunner.RunAsync(
                "docker", ["volume", "inspect", volume, "--format", "{{.Mountpoint}}"],
                logSource: "sweeper", streamOutput: false, cancellationToken: cancellationToken)
                .ConfigureAwait(false);

            if (!inspect.Succeeded) continue;

            keep.Add(new DiskUsageItem
            {
                Description = $"volume {volume}",
                Category = DiskCategory.Keep,
                Bytes = DirectorySize(inspect.StandardOutput.Trim()),
                Reason = "Deleting this is what makes the next build re-clone JUCE from scratch.",
            });
        }

        string cacheDir = Path.Combine(workDir, "cache");
        if (Directory.Exists(cacheDir))
        {
            keep.Add(new DiskUsageItem
            {
                Description = $"cache {cacheDir}",
                Category = DiskCategory.Keep,
                Bytes = DirectorySize(cacheDir),
                Reason = "Compiler and dependency caches. Kept for speed.",
            });
        }

        foreach ((string relative, string description) in SweeperPolicy.PurgeDirectories)
        {
            string full = Path.Combine(workDir, relative);
            if (!Directory.Exists(full)) continue;
            purge.Add(new DiskUsageItem
            {
                Description = $"{description} {full}",
                Category = DiskCategory.Purge,
                Bytes = DirectorySize(full),
            });
        }

        long oldLogBytes = OldLogBytes(workDir, config.Retention.LogRetentionDays);
        if (oldLogBytes > 0)
        {
            purge.Add(new DiskUsageItem
            {
                Description = $"logs older than {config.Retention.LogRetentionDays} days",
                Category = DiskCategory.Purge,
                Bytes = oldLogBytes,
            });
        }

        return new DiskUsage { Keep = keep, Purge = purge };
    }

    /// <summary>Runs the sweep and reports the bytes actually reclaimed.</summary>
    public async Task<long> PurgeAsync(ForgeConfig config, CancellationToken cancellationToken = default)
    {
        DiskUsage before = await SurveyAsync(config, cancellationToken).ConfigureAwait(false);
        _logBus.Info("sweeper", $"reclaimable: {before.HumanReclaimableBytes}");

        string workDir = config.Paths.WorkDir;

        foreach ((string relative, string description) in SweeperPolicy.PurgeDirectories)
        {
            string full = Path.Combine(workDir, relative);
            if (!Directory.Exists(full)) continue;
            _logBus.Info("sweeper", $"removing {description}");
            TryDeleteChildren(full);
        }

        DeleteOldLogs(workDir, config.Retention.LogRetentionDays);
        DeleteOldProofBundles(workDir);

        // Stopped containers, then TARGETED prunes only.
        ProcessResult stopped = await _processRunner.RunAsync(
            "docker", ["ps", "-a", "--filter", "status=exited", "--filter", "status=created",
                       "--filter", "status=dead", "--format", "{{.ID}}"],
            logSource: "sweeper", streamOutput: false, cancellationToken: cancellationToken).ConfigureAwait(false);

        string[] ids = stopped.StandardOutput
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        if (ids.Length > 0)
        {
            _logBus.Info("sweeper", $"removing {ids.Length} stopped container(s)");
            await _processRunner.RunAsync("docker", ["rm", "-f", .. ids],
                logSource: "sweeper", cancellationToken: cancellationToken).ConfigureAwait(false);
        }

        // `docker image prune -f` removes only DANGLING images and never a
        // tagged one, so every KEEP tag survives. `system prune -a` would delete
        // them and is never used.
        _logBus.Info("sweeper", "pruning dangling images and build cache (never 'system prune -a')");
        await _processRunner.RunAsync("docker", ["image", "prune", "-f"],
            logSource: "sweeper", cancellationToken: cancellationToken).ConfigureAwait(false);
        await _processRunner.RunAsync("docker", ["builder", "prune", "-f"],
            logSource: "sweeper", cancellationToken: cancellationToken).ConfigureAwait(false);

        DiskUsage after = await SurveyAsync(config, cancellationToken).ConfigureAwait(false);
        long reclaimed = Math.Max(0, before.ReclaimableBytes - after.ReclaimableBytes);
        _logBus.Info("sweeper", $"reclaimed {DiskUsageItem.FormatBytes(reclaimed)}");
        return reclaimed;
    }

    private static long DirectorySize(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return 0;
        try
        {
            return new DirectoryInfo(path)
                .EnumerateFiles("*", SearchOption.AllDirectories)
                .Sum(f => f.Length);
        }
        catch (Exception)
        {
            // A directory we cannot enumerate is not worth failing a survey over.
            return 0;
        }
    }

    private static long OldLogBytes(string workDir, int retentionDays)
    {
        string logs = Path.Combine(workDir, "logs");
        if (!Directory.Exists(logs)) return 0;
        DateTime cutoff = DateTime.Now.AddDays(-retentionDays);
        try
        {
            return new DirectoryInfo(logs)
                .EnumerateFiles("*", SearchOption.AllDirectories)
                .Where(f => f.LastWriteTime < cutoff)
                .Sum(f => f.Length);
        }
        catch (Exception) { return 0; }
    }

    private void DeleteOldLogs(string workDir, int retentionDays)
    {
        string logs = Path.Combine(workDir, "logs");
        if (!Directory.Exists(logs)) return;
        DateTime cutoff = DateTime.Now.AddDays(-retentionDays);

        foreach (FileInfo file in new DirectoryInfo(logs).EnumerateFiles("*", SearchOption.AllDirectories))
        {
            if (file.LastWriteTime >= cutoff) continue;
            try { file.Delete(); }
            catch (Exception ex) { _logBus.Warning("sweeper", $"could not delete {file.FullName}: {ex.Message}"); }
        }
    }

    /// <summary>
    /// Keeps the most recent proof bundle. It is what the Runners page shows as
    /// "currently known-good"; deleting it would make the GUI claim the setup
    /// has never been verified.
    /// </summary>
    private void DeleteOldProofBundles(string workDir)
    {
        string proof = Path.Combine(workDir, "proof");
        if (!Directory.Exists(proof)) return;

        List<DirectoryInfo> bundles = [.. new DirectoryInfo(proof)
            .EnumerateDirectories()
            .OrderByDescending(d => d.LastWriteTime)];

        foreach (DirectoryInfo bundle in bundles.Skip(1))
        {
            try { bundle.Delete(recursive: true); }
            catch (Exception ex) { _logBus.Warning("sweeper", $"could not delete {bundle.FullName}: {ex.Message}"); }
        }
    }

    private void TryDeleteChildren(string directory)
    {
        foreach (string child in Directory.EnumerateFileSystemEntries(directory))
        {
            try
            {
                if (Directory.Exists(child)) Directory.Delete(child, recursive: true);
                else File.Delete(child);
            }
            catch (Exception ex)
            {
                _logBus.Warning("sweeper", $"could not delete {child}: {ex.Message}");
            }
        }
    }
}

/// <summary>
/// The KEEP/PURGE policy as pure data and pure functions, so it can be proven
/// without a Docker daemon or a disk.
/// </summary>
public static class SweeperPolicy
{
    /// <summary>Named volumes that are never deleted.</summary>
    public static IReadOnlyList<string> KeepVolumes { get; } =
        ["forge-fetchcontent", "forge-sccache", "forge-ccache", "forge-aax-sdk"];

    /// <summary>Image tags that are never deleted, given the configured versions.</summary>
    public static IReadOnlyList<string> KeepImageTags(string windowsTag, string linuxTag) =>
    [
        $"runnerforge/win-build:{windowsTag}",
        $"runnerforge/linux-util:{linuxTag}",
        "mcr.microsoft.com/windows/servercore:ltsc2022",
        "ubuntu:24.04",
    ];

    /// <summary>Work-directory subtrees that are always purged.</summary>
    public static IReadOnlyList<(string Relative, string Description)> PurgeDirectories { get; } =
    [
        ("jobs", "job workspaces"),
        ("tmp", "temp downloads"),
    ];

    /// <summary>Container states that are safe to remove.</summary>
    public static IReadOnlyList<string> PurgeContainerStates { get; } = ["exited", "created", "dead"];

    /// <summary>
    /// The prune commands the sweeper is allowed to run. Deliberately explicit:
    /// this list is what a test asserts against to prove `system prune -a` is
    /// not reachable.
    /// </summary>
    public static IReadOnlyList<string> AllowedPruneCommands { get; } =
        ["docker image prune -f", "docker builder prune -f"];

    /// <summary>True when a command would destroy KEEP items.</summary>
    public static bool IsForbiddenPrune(string command) =>
        command.Contains("system prune", StringComparison.OrdinalIgnoreCase)
        || (command.Contains("image prune", StringComparison.OrdinalIgnoreCase)
            && command.Contains(" -a", StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Whether a Tart entry may be deleted. Only CLONES (forge-*) may be; an
    /// image never may, because rebuilding one costs an hour.
    /// </summary>
    public static bool IsDeletableTartEntry(string name) =>
        name.StartsWith("forge-", StringComparison.Ordinal);

    /// <summary>True when the named item must survive every sweep.</summary>
    public static bool IsKeepItem(string name, string windowsTag, string linuxTag) =>
        KeepVolumes.Contains(name)
        || KeepImageTags(windowsTag, linuxTag).Contains(name)
        || name.StartsWith("runnerforge-macos:", StringComparison.Ordinal)
        || name.Contains("macos-tahoe-xcode", StringComparison.Ordinal);
}
