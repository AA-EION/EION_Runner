using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;
using RunnerForge.Models;

namespace RunnerForge.Services;

public enum ReplicaState { Stopped, Starting, WaitingForJob, RunningJob, CleaningUp, Error }

/// <summary>One live runner, as the Runners page sees it.</summary>
public sealed class ReplicaStatus
{
    public required string ClassId { get; init; }
    public required int Index { get; init; }
    public string RunnerName { get; set; } = "";
    public ReplicaState State { get; set; } = ReplicaState.Stopped;
    public DateTimeOffset? StartedAt { get; set; }
    public string? CurrentJobId { get; set; }
    public int JobsCompletedToday { get; set; }
    public string? LastError { get; set; }

    public TimeSpan Uptime => StartedAt is null ? TimeSpan.Zero : DateTimeOffset.UtcNow - StartedAt.Value;
}

/// <summary>Crash-safe record of what was running, written before launch.</summary>
public sealed class SupervisorState
{
    [JsonPropertyName("runners")] public List<SupervisorRunnerEntry> Runners { get; set; } = [];
}

public sealed class SupervisorRunnerEntry
{
    [JsonPropertyName("runnerName")] public string RunnerName { get; set; } = "";
    [JsonPropertyName("classId")] public string ClassId { get; set; } = "";
    [JsonPropertyName("containerId")] public string? ContainerId { get; set; }
    [JsonPropertyName("pid")] public int? Pid { get; set; }
    [JsonPropertyName("startedAt")] public DateTimeOffset StartedAt { get; set; }
    [JsonPropertyName("repo")] public string Repo { get; set; } = "";
}

/// <summary>
/// Starts, watches and replaces ephemeral runners.
/// </summary>
/// <remarks>
/// Every runner takes ONE job and dies. State is written to
/// <c>paths.workDir/state.json</c> BEFORE a process is launched, so a hard power
/// cut leaves a record the next launch can clean up rather than an orphan nobody
/// knows about.
/// </remarks>
public sealed class RunnerSupervisor(
    LogBus logBus,
    DockerService dockerService,
    GitHubAppService appService,
    GitHubActionsService actionsService,
    ReaperService reaperService)
{
    private readonly LogBus _logBus = logBus;
    private readonly DockerService _dockerService = dockerService;
    private readonly GitHubAppService _appService = appService;
    private readonly GitHubActionsService _actionsService = actionsService;
    private readonly ReaperService _reaperService = reaperService;

    private readonly ConcurrentDictionary<string, ReplicaStatus> _replicas = new();
    private readonly ConcurrentDictionary<string, CancellationTokenSource> _cancellations = new();
    private readonly ConcurrentDictionary<string, List<DateTimeOffset>> _recentFailures = new();
    private readonly Lock _stateLock = new();

    /// <summary>
    /// Three non-zero exits within five minutes stops the class. A broken class —
    /// bad image, wrong labels, revoked key — must never hot-loop against the
    /// GitHub API.
    /// </summary>
    public const int FailureThreshold = 3;
    public static readonly TimeSpan FailureWindow = TimeSpan.FromMinutes(5);

    public event Action? StatusChanged;

    public IReadOnlyCollection<ReplicaStatus> Replicas => [.. _replicas.Values];

    /// <summary>Set when the Reaper reported survivors. Blocks new runners until acknowledged.</summary>
    public bool BlockedByStraySurvivors { get; private set; }

    public IReadOnlyList<string> StraySurvivorDetails { get; private set; } = [];

    public void AcknowledgeStraySurvivors()
    {
        BlockedByStraySurvivors = false;
        StraySurvivorDetails = [];
        StatusChanged?.Invoke();
    }

    private static string KeyFor(string classId, int index) => $"{classId}#{index}";

    public async Task StartClassAsync(
        ForgeConfig config, RunnerClass runnerClass, CancellationToken cancellationToken = default)
    {
        if (BlockedByStraySurvivors)
        {
            _logBus.Error("supervisor",
                "refusing to start runners: the Reaper reported survivors that must be acknowledged first.");
            return;
        }

        RunnerConfig? runnerConfig = config.Runners.FirstOrDefault(r => r.ClassId == runnerClass.ClassId);
        if (runnerConfig is null || !runnerConfig.Enabled)
        {
            _logBus.Warning("supervisor", $"{runnerClass.ClassId} is not enabled");
            return;
        }

        int replicas = runnerClass.ReplicasAreFixed ? 1 : runnerConfig.Replicas;

        for (int index = 0; index < replicas; index++)
        {
            string key = KeyFor(runnerClass.ClassId, index);
            if (_replicas.TryGetValue(key, out ReplicaStatus? existing)
                && existing.State is not (ReplicaState.Stopped or ReplicaState.Error))
            {
                continue;
            }

            var status = new ReplicaStatus { ClassId = runnerClass.ClassId, Index = index };
            _replicas[key] = status;

            var cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _cancellations[key] = cancellation;

            _ = Task.Run(() => RunReplicaLoopAsync(config, runnerClass, status, key, cancellation.Token),
                         cancellation.Token);
        }

        StatusChanged?.Invoke();
        await Task.CompletedTask.ConfigureAwait(false);
    }

    /// <summary>
    /// One replica's whole life: mint a JIT config, run one job, reap, replace.
    /// </summary>
    private async Task RunReplicaLoopAsync(
        ForgeConfig config, RunnerClass runnerClass, ReplicaStatus status, string key,
        CancellationToken cancellationToken)
    {
        string repo = config.GitHub.Repos.FirstOrDefault() ?? "";

        while (!cancellationToken.IsCancellationRequested)
        {
            if (IsBackingOff(runnerClass.ClassId))
            {
                status.State = ReplicaState.Error;
                status.LastError = $"stopped after {FailureThreshold} failures within "
                                   + $"{FailureWindow.TotalMinutes:0} minutes";
                _logBus.Error("supervisor",
                    $"{runnerClass.ClassId}: {status.LastError}. Not retrying — a broken class must not hot-loop.");
                StatusChanged?.Invoke();
                return;
            }

            try
            {
                status.State = ReplicaState.Starting;
                StatusChanged?.Invoke();

                JitConfig jit = await _appService
                    .GenerateJitConfigAsync(config, repo, runnerClass, cancellationToken).ConfigureAwait(false);

                status.RunnerName = jit.RunnerName;
                status.StartedAt = DateTimeOffset.UtcNow;
                status.State = ReplicaState.WaitingForJob;
                StatusChanged?.Invoke();

                // Recorded BEFORE launch: a crash between here and exit leaves a
                // record the next start can reap.
                RecordState(config, new SupervisorRunnerEntry
                {
                    RunnerName = jit.RunnerName,
                    ClassId = runnerClass.ClassId,
                    StartedAt = DateTimeOffset.UtcNow,
                    Repo = repo,
                });

                ProcessResult result = await StartRunnerProcessAsync(
                    config, runnerClass, jit, cancellationToken).ConfigureAwait(false);

                status.State = ReplicaState.CleaningUp;
                StatusChanged?.Invoke();

                ForgetState(config, jit.RunnerName);

                if (result.ExitCode != 0)
                {
                    RecordFailure(runnerClass.ClassId);
                    status.LastError = $"exit code {result.ExitCode}";
                    _logBus.Warning("supervisor",
                        $"{jit.RunnerName} exited with {result.ExitCode}");
                }
                else
                {
                    status.JobsCompletedToday++;
                    ClearFailures(runnerClass.ClassId);
                }

                await ReapScopedAsync(config, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                RecordFailure(runnerClass.ClassId);
                status.State = ReplicaState.Error;
                status.LastError = ex.Message;
                _logBus.Error("supervisor", $"{runnerClass.ClassId} replica {status.Index}: {ex.Message}");
                StatusChanged?.Invoke();
                await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false);
            }
        }

        status.State = ReplicaState.Stopped;
        status.StartedAt = null;
        StatusChanged?.Invoke();
    }

    private async Task<ProcessResult> StartRunnerProcessAsync(
        ForgeConfig config, RunnerClass runnerClass, JitConfig jit, CancellationToken cancellationToken)
    {
        var mounts = new Dictionary<string, string>();

        switch (runnerClass.Isolation)
        {
            case RunnerIsolation.WindowsContainer:
                mounts["forge-fetchcontent"] = @"C:\cache\fetchcontent";
                mounts["forge-sccache"] = @"C:\cache\sccache";
                mounts["forge-aax-sdk"] = @"C:\sdk\aax";
                return await _dockerService.RunEphemeralAsync(
                    "runnerforge/win-build:1.0.0", jit.RunnerName, jit, mounts, "4", "8g", cancellationToken)
                    .ConfigureAwait(false);

            case RunnerIsolation.LinuxContainer:
                mounts["forge-fetchcontent"] = "/cache/fetchcontent";
                mounts["forge-ccache"] = "/cache/ccache";
                mounts["forge-aax-sdk"] = "/sdk/aax";
                return await _dockerService.RunEphemeralAsync(
                    "runnerforge/linux-util:1.0.0", jit.RunnerName, jit, mounts, "4", "8g", cancellationToken)
                    .ConfigureAwait(false);

            case RunnerIsolation.TartVmClone:
                // macOS runners live on the Mac. This app never virtualizes macOS:
                // it is impossible on this hardware and against Apple's licence.
                throw new PlatformNotSupportedException(
                    "mac-build runs on the Apple Silicon host, not on Windows. macOS cannot be virtualized "
                    + "on non-Apple hardware — not in Docker, QEMU, KVM or WSL.");

            case RunnerIsolation.HostProcess:
                throw new NotSupportedException(
                    "The iLok classes are started by the signing workflow on the machine holding the dongle, "
                    + "not by the supervisor.");

            default:
                throw new ArgumentOutOfRangeException(nameof(runnerClass));
        }
    }

    private async Task ReapScopedAsync(ForgeConfig config, CancellationToken cancellationToken)
    {
        int[] livePids = [.. _replicas.Values
            .Where(r => r.State is ReplicaState.RunningJob or ReplicaState.WaitingForJob)
            .Select(_ => Environment.ProcessId)];

        string[] liveNames = [.. _replicas.Values
            .Where(r => !string.IsNullOrEmpty(r.RunnerName)
                        && r.State is ReplicaState.RunningJob or ReplicaState.WaitingForJob)
            .Select(r => r.RunnerName)];

        ReaperResult result = await _reaperService
            .ReapAsync(config, livePids, liveNames, cancellationToken).ConfigureAwait(false);

        if (result == ReaperResult.StraysSurvived)
        {
            BlockedByStraySurvivors = true;
            IReadOnlyList<Stray> survivors = await _reaperService
                .FindStraysAsync(config, livePids, liveNames, cancellationToken).ConfigureAwait(false);
            StraySurvivorDetails = [.. survivors.Select(s => s.Detail)];
            StatusChanged?.Invoke();
        }
    }

    public async Task StopClassAsync(RunnerClass runnerClass)
    {
        foreach ((string key, CancellationTokenSource cancellation) in _cancellations)
        {
            if (!key.StartsWith(runnerClass.ClassId + "#", StringComparison.Ordinal)) continue;
            await cancellation.CancelAsync().ConfigureAwait(false);
        }
        StatusChanged?.Invoke();
    }

    /// <summary>
    /// Refuses new jobs and waits for in-flight ones, then forces. Called on app
    /// close, so the user never loses a running build to a window close.
    /// </summary>
    public async Task DrainAsync(TimeSpan timeout, IProgress<string>? progress = null)
    {
        progress?.Report("refusing new jobs");
        foreach (CancellationTokenSource cancellation in _cancellations.Values)
        {
            await cancellation.CancelAsync().ConfigureAwait(false);
        }

        DateTimeOffset deadline = DateTimeOffset.UtcNow + timeout;

        while (DateTimeOffset.UtcNow < deadline)
        {
            int inFlight = _replicas.Values.Count(r => r.State == ReplicaState.RunningJob);
            if (inFlight == 0) break;
            progress?.Report($"waiting for {inFlight} in-flight job(s)");
            await Task.Delay(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        }

        progress?.Report("drained");
    }

    /// <summary>
    /// On start, reap anything recorded but not alive, and remove any offline
    /// forge-* registration left dangling on GitHub by a crash.
    /// </summary>
    public async Task RecoverFromCrashAsync(ForgeConfig config, CancellationToken cancellationToken = default)
    {
        SupervisorState state = ReadState(config);
        if (state.Runners.Count > 0)
        {
            _logBus.Warning("supervisor",
                $"state.json records {state.Runners.Count} runner(s) from a previous session; reaping");
            await _reaperService.ReapAsync(config, [], [], cancellationToken).ConfigureAwait(false);
            WriteState(config, new SupervisorState());
        }

        foreach (string repo in config.GitHub.Repos)
        {
            try
            {
                IReadOnlyList<(long Id, string Name, string Status)> runners = await _actionsService
                    .ListSelfHostedRunnersAsync(config, repo, cancellationToken).ConfigureAwait(false);

                foreach ((long id, string name, string status) in runners)
                {
                    if (!name.StartsWith("forge-", StringComparison.Ordinal)) continue;
                    if (!string.Equals(status, "offline", StringComparison.OrdinalIgnoreCase)) continue;

                    _logBus.Info("supervisor", $"removing offline registration {name} from {repo}");
                    await _actionsService.DeleteRunnerAsync(config, repo, id, cancellationToken)
                        .ConfigureAwait(false);
                }
            }
            catch (Exception ex)
            {
                _logBus.Warning("supervisor", $"crash recovery could not query {repo}: {ex.Message}");
            }
        }
    }

    // --- backoff -----------------------------------------------------------
    private bool IsBackingOff(string classId)
    {
        if (!_recentFailures.TryGetValue(classId, out List<DateTimeOffset>? failures)) return false;
        lock (_stateLock)
        {
            failures.RemoveAll(f => DateTimeOffset.UtcNow - f > FailureWindow);
            return failures.Count >= FailureThreshold;
        }
    }

    private void RecordFailure(string classId)
    {
        List<DateTimeOffset> failures = _recentFailures.GetOrAdd(classId, _ => []);
        lock (_stateLock) failures.Add(DateTimeOffset.UtcNow);
    }

    private void ClearFailures(string classId)
    {
        if (_recentFailures.TryGetValue(classId, out List<DateTimeOffset>? failures))
        {
            lock (_stateLock) failures.Clear();
        }
    }

    // --- crash-safe state --------------------------------------------------
    private static string StatePath(ForgeConfig config) => Path.Combine(config.Paths.WorkDir, "state.json");

    private SupervisorState ReadState(ForgeConfig config)
    {
        string path = StatePath(config);
        if (!File.Exists(path)) return new SupervisorState();
        try
        {
            return JsonSerializer.Deserialize<SupervisorState>(File.ReadAllText(path)) ?? new SupervisorState();
        }
        catch (Exception ex)
        {
            _logBus.Warning("supervisor", $"could not read state.json: {ex.Message}");
            return new SupervisorState();
        }
    }

    private void WriteState(ForgeConfig config, SupervisorState state)
    {
        try
        {
            Directory.CreateDirectory(config.Paths.WorkDir);
            File.WriteAllText(StatePath(config),
                JsonSerializer.Serialize(state, ForgeConfig.SerializerOptions));
        }
        catch (Exception ex)
        {
            _logBus.Warning("supervisor", $"could not write state.json: {ex.Message}");
        }
    }

    private void RecordState(ForgeConfig config, SupervisorRunnerEntry entry)
    {
        lock (_stateLock)
        {
            SupervisorState state = ReadState(config);
            state.Runners.Add(entry);
            WriteState(config, state);
        }
    }

    private void ForgetState(ForgeConfig config, string runnerName)
    {
        lock (_stateLock)
        {
            SupervisorState state = ReadState(config);
            state.Runners.RemoveAll(r => r.RunnerName == runnerName);
            WriteState(config, state);
        }
    }
}
