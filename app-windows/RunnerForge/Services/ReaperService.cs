using System.Diagnostics;
using RunnerForge.Models;

namespace RunnerForge.Services;

/// <summary>Reaper outcome. These values are the contract with the GUI.</summary>
public enum ReaperResult
{
    /// <summary>Nothing stray was found.</summary>
    Clean = 0,

    /// <summary>Strays were found and are now gone.</summary>
    StraysKilled = 10,

    /// <summary>Something ignored Kill(). The GUI must refuse to start new runners.</summary>
    StraysSurvived = 20,
}

public sealed record Stray(string Kind, string Name, int? ProcessId, string Detail);

/// <summary>
/// "Verify nothing keeps running."
/// </summary>
/// <remarks>
/// Answers exactly one question: is anything still alive that should not be? It
/// does NOT decide what to delete — that is the Sweeper's job. Keeping them
/// apart matters because "is it running?" and "can I delete it?" have different
/// answers and different blast radii.
/// </remarks>
public sealed class ReaperService(LogBus logBus, ProcessRunner processRunner)
{
    private readonly LogBus _logBus = logBus;
    private readonly ProcessRunner _processRunner = processRunner;

    /// <summary>
    /// Processes that must not exist outside a live, registered job. MSBuild and
    /// mspdbsrv in particular are notorious for outliving the job that spawned
    /// them, holding file locks on a machine the user believes is idle.
    /// </summary>
    public static IReadOnlyList<string> StrayProcessNames { get; } =
    [
        "Runner.Listener", "Runner.Worker", "MSBuild", "cl", "link",
        "cmake", "ninja", "ISCC", "wraptool", "mspdbsrv", "vctip",
    ];

    public TimeSpan Grace { get; set; } = TimeSpan.FromSeconds(10);

    /// <summary>Finds strays without touching anything. Used by the watchdog poll.</summary>
    public async Task<IReadOnlyList<Stray>> FindStraysAsync(
        ForgeConfig config,
        IReadOnlyCollection<int> livePids,
        IReadOnlyCollection<string> liveRunnerNames,
        CancellationToken cancellationToken = default)
    {
        var strays = new List<Stray>();
        int selfPid = Environment.ProcessId;

        foreach (string name in StrayProcessNames)
        {
            Process[] found;
            try { found = Process.GetProcessesByName(name); }
            catch (Exception) { continue; }

            foreach (Process process in found)
            {
                try
                {
                    if (process.Id == selfPid || livePids.Contains(process.Id)) continue;
                    strays.Add(new Stray("process", name, process.Id,
                        $"{name} pid={process.Id} started {process.StartTime:HH:mm:ss}"));
                }
                catch (Exception)
                {
                    // A process that exited between enumeration and inspection is
                    // not a stray; it is already gone.
                }
                finally { process.Dispose(); }
            }
        }

        // `dotnet` counts only when it is running out of the work directory; the
        // machine's own dotnet processes are none of our business.
        foreach (Process process in Process.GetProcessesByName("dotnet"))
        {
            try
            {
                if (process.Id == selfPid || livePids.Contains(process.Id)) continue;
                string? path = process.MainModule?.FileName;
                if (path is not null && path.StartsWith(config.Paths.WorkDir, StringComparison.OrdinalIgnoreCase))
                {
                    strays.Add(new Stray("process", "dotnet", process.Id, $"dotnet pid={process.Id} at {path}"));
                }
            }
            catch (Exception) { }
            finally { process.Dispose(); }
        }

        // Containers still running whose job has ended.
        ProcessResult running = await _processRunner.RunAsync(
            "docker", ["ps", "--filter", "status=running", "--format", "{{.ID}} {{.Names}}"],
            logSource: "reaper", streamOutput: false, cancellationToken: cancellationToken).ConfigureAwait(false);

        foreach (string line in running.StandardOutput
                     .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            string[] parts = line.Split(' ', 2);
            if (parts.Length < 2) continue;
            string containerName = parts[1];

            if (!containerName.StartsWith("forge-", StringComparison.Ordinal)) continue;
            if (liveRunnerNames.Any(live => containerName.Contains(live, StringComparison.Ordinal))) continue;

            strays.Add(new Stray("container", containerName, null, $"container {containerName} ({parts[0]})"));
        }

        return strays;
    }

    /// <summary>
    /// Finds strays, terminates them politely, escalates, and RE-VERIFIES.
    /// Reporting "killed" without checking is how a stray survives a reap and
    /// nobody notices.
    /// </summary>
    public async Task<ReaperResult> ReapAsync(
        ForgeConfig config,
        IReadOnlyCollection<int> livePids,
        IReadOnlyCollection<string> liveRunnerNames,
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<Stray> strays =
            await FindStraysAsync(config, livePids, liveRunnerNames, cancellationToken).ConfigureAwait(false);

        if (strays.Count == 0)
        {
            _logBus.Info("reaper", "clean: no stray processes or containers");
            return ReaperResult.Clean;
        }

        _logBus.Warning("reaper", $"found {strays.Count} stray item(s)");
        foreach (Stray stray in strays) _logBus.Warning("reaper", "  " + stray.Detail);

        // Polite first. A runner given the chance to shut down cleanly
        // unregisters itself from GitHub; one killed outright leaves an offline
        // registration behind for crash recovery to clean up.
        foreach (Stray stray in strays.Where(s => s.Kind == "process" && s.ProcessId is not null))
        {
            try
            {
                using Process process = Process.GetProcessById(stray.ProcessId!.Value);
                _logBus.Info("reaper", $"CloseMainWindow -> {stray.ProcessId}");
                process.CloseMainWindow();
            }
            catch (Exception) { }
        }

        DateTimeOffset deadline = DateTimeOffset.UtcNow + Grace;
        while (DateTimeOffset.UtcNow < deadline && AnyAlive(strays))
        {
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        }

        foreach (Stray stray in strays.Where(s => s.Kind == "process" && s.ProcessId is not null))
        {
            try
            {
                using Process process = Process.GetProcessById(stray.ProcessId!.Value);
                _logBus.Warning("reaper", $"Kill -> {stray.ProcessId} (ignored CloseMainWindow)");
                process.Kill(entireProcessTree: true);
            }
            catch (Exception) { }
        }

        foreach (Stray stray in strays.Where(s => s.Kind == "container"))
        {
            await _processRunner.RunAsync("docker", ["rm", "-f", stray.Name],
                logSource: "reaper", streamOutput: false, cancellationToken: cancellationToken).ConfigureAwait(false);
        }

        await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);

        IReadOnlyList<Stray> survivors =
            await FindStraysAsync(config, livePids, liveRunnerNames, cancellationToken).ConfigureAwait(false);

        if (survivors.Count > 0)
        {
            _logBus.Error("reaper", $"STRAYS SURVIVED — {survivors.Count} item(s) are still present after Kill:");
            foreach (Stray survivor in survivors) _logBus.Error("reaper", "  " + survivor.Detail);
            _logBus.Error("reaper", "new runners must not be started until this is resolved.");
            return ReaperResult.StraysSurvived;
        }

        _logBus.Info("reaper", $"all {strays.Count} stray item(s) confirmed gone");
        return ReaperResult.StraysKilled;
    }

    private static bool AnyAlive(IEnumerable<Stray> strays)
    {
        foreach (Stray stray in strays)
        {
            if (stray.ProcessId is null) continue;
            try
            {
                using Process process = Process.GetProcessById(stray.ProcessId.Value);
                if (!process.HasExited) return true;
            }
            catch (ArgumentException)
            {
                // No such process: it is gone, which is what we wanted.
            }
        }
        return false;
    }
}
