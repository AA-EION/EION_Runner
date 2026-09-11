using System.Text.Json.Nodes;
using RunnerForge.Models;

namespace RunnerForge.Services;

public sealed record DockerStatus(bool CliPresent, bool DaemonReachable, string? OsType, string? Version);

/// <summary>
/// Everything Runner Forge asks of Docker: status, image builds, and starting a
/// container with a single-use JIT config.
/// </summary>
public sealed class DockerService(LogBus logBus, ProcessRunner processRunner)
{
    private readonly LogBus _logBus = logBus;
    private readonly ProcessRunner _processRunner = processRunner;

    public async Task<DockerStatus> GetStatusAsync(CancellationToken cancellationToken = default)
    {
        if (!ProcessRunner.IsOnPath("docker"))
        {
            return new DockerStatus(false, false, null, null);
        }

        ProcessResult info = await _processRunner.RunAsync(
            "docker", ["info", "--format", "{{.OSType}}|{{.ServerVersion}}"],
            logSource: "docker", streamOutput: false, cancellationToken: cancellationToken).ConfigureAwait(false);

        if (!info.Succeeded)
        {
            // "Installed" and "answering" fail independently and have different
            // fixes, so they are reported separately.
            return new DockerStatus(true, false, null, null);
        }

        string[] parts = info.StandardOutput.Trim().Split('|');
        return new DockerStatus(true, true,
            parts.ElementAtOrDefault(0), parts.ElementAtOrDefault(1));
    }

    // -----------------------------------------------------------------------
    // Engines.
    //
    // Docker Desktop on Windows runs two daemons — the Windows container engine
    // and the Linux one in WSL2 — but the CLI endpoint
    // (npipe:////./pipe/docker_engine) points at exactly ONE of them at a time.
    // There is no supported way to address both through the same endpoint;
    // LCOW, which once allowed it, was experimental and is gone.
    //
    // The fact that makes this workable, and that the old design missed:
    // SWITCHING DOES NOT STOP RUNNING CONTAINERS. Containers started under one
    // engine keep running while the CLI is pointed at the other. So a machine
    // CAN host win-build and linux-util at the same time. What it cannot do is
    // START or INSPECT both through one endpoint at one moment.
    //
    // Therefore the engine is a per-operation concern, not a machine-wide mode
    // the user has to set up front. Each class selects the engine it needs at
    // the moment it starts, and anything that enumerates containers has to ask
    // both engines rather than whichever one happens to be selected.
    // -----------------------------------------------------------------------

    /// <summary>Which of Docker Desktop's two daemons an operation needs.</summary>
    public enum DockerEngine { Windows, Linux }

    private static string DockerCliPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        "Docker", "Docker", "DockerCli.exe");

    /// <summary>True when this machine has the switching tool Docker Desktop ships.</summary>
    public static bool CanSwitchEngines => File.Exists(DockerCliPath);

    /// <summary>Switches Docker Desktop to the Windows engine.</summary>
    public Task<bool> SwitchToWindowsContainersAsync(CancellationToken cancellationToken = default) =>
        SwitchEngineAsync(DockerEngine.Windows, cancellationToken);

    /// <summary>Points the CLI endpoint at one of the two daemons.</summary>
    public async Task<bool> SwitchEngineAsync(
        DockerEngine engine, CancellationToken cancellationToken = default)
    {
        if (!CanSwitchEngines)
        {
            _logBus.Error("docker", $"DockerCli.exe not found at {DockerCliPath}");
            return false;
        }

        string flag = engine == DockerEngine.Windows ? "-SwitchWindowsEngine" : "-SwitchLinuxEngine";

        ProcessResult result = await _processRunner.RunAsync(
            DockerCliPath, [flag], logSource: "docker", cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        return result.Succeeded;
    }

    /// <summary>
    /// Makes the given engine the selected one, switching only if it is not
    /// already, and waiting for the daemon to answer again afterwards.
    /// </summary>
    /// <remarks>
    /// The switch restarts the endpoint, so the first command after it can fail
    /// with "the docker daemon is not running" even though the switch worked.
    /// Polling until it answers turns that race into a wait.
    /// </remarks>
    public async Task<bool> EnsureEngineAsync(
        DockerEngine engine, CancellationToken cancellationToken = default)
    {
        string wanted = engine == DockerEngine.Windows ? "windows" : "linux";

        DockerStatus status = await GetStatusAsync(cancellationToken).ConfigureAwait(false);
        if (status.DaemonReachable && status.OsType == wanted) return true;

        _logBus.Info("docker",
            $"selecting the {wanted} engine (currently {status.OsType ?? "unreachable"}). "
            + "Containers already running under the other engine keep running.");

        if (!await SwitchEngineAsync(engine, cancellationToken).ConfigureAwait(false)) return false;

        for (int attempt = 0; attempt < 30; attempt++)
        {
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false);

            status = await GetStatusAsync(cancellationToken).ConfigureAwait(false);
            if (status.DaemonReachable && status.OsType == wanted)
            {
                _logBus.Info("docker", $"the {wanted} engine is answering");
                return true;
            }
        }

        _logBus.Error("docker", $"the {wanted} engine did not come up within 60s");
        return false;
    }

    /// <summary>
    /// Container names across BOTH engines, with the engine that holds each.
    /// </summary>
    /// <remarks>
    /// The Reaper and the Sweeper must use this rather than ListContainersAsync.
    /// A single `docker ps` sees only the selected engine, so a reap performed
    /// in Windows mode would silently leave every Linux container behind —
    /// exactly the stray state the Reaper exists to prevent.
    ///
    /// The engine selected on entry is restored on exit, so this is invisible to
    /// anything else in flight.
    /// </remarks>
    public async Task<IReadOnlyList<(string Name, DockerEngine Engine)>> ListContainersAcrossEnginesAsync(
        string? statusFilter = null, CancellationToken cancellationToken = default)
    {
        var found = new List<(string, DockerEngine)>();

        DockerStatus initial = await GetStatusAsync(cancellationToken).ConfigureAwait(false);
        if (!initial.DaemonReachable) return found;

        DockerEngine? restore = initial.OsType switch
        {
            "windows" => DockerEngine.Windows,
            "linux" => DockerEngine.Linux,
            _ => null,
        };

        // Without the switching tool there is only ever one reachable engine, so
        // report that one rather than pretending to have looked at both.
        if (!CanSwitchEngines)
        {
            foreach (string name in await ListContainersAsync(statusFilter, cancellationToken).ConfigureAwait(false))
            {
                found.Add((name, restore ?? DockerEngine.Linux));
            }
            return found;
        }

        try
        {
            foreach (DockerEngine engine in (DockerEngine[])[DockerEngine.Windows, DockerEngine.Linux])
            {
                if (!await EnsureEngineAsync(engine, cancellationToken).ConfigureAwait(false))
                {
                    _logBus.Warning("docker",
                        $"could not select the {engine} engine while enumerating containers; "
                        + "anything it holds is not listed here");
                    continue;
                }

                foreach (string name in await ListContainersAsync(statusFilter, cancellationToken).ConfigureAwait(false))
                {
                    found.Add((name, engine));
                }
            }
        }
        finally
        {
            if (restore is not null)
            {
                await EnsureEngineAsync(restore.Value, cancellationToken).ConfigureAwait(false);
            }
        }

        return found;
    }

    /// <summary>
    /// Builds a runner image from the DECLARED toolchain.
    /// </summary>
    /// <remarks>
    /// Versions, URLs, checksums and package lists all come from versions.toml
    /// and are passed as build arguments. NO SECRET is ever passed here:
    /// --build-arg values are recorded in the image history and are readable by
    /// anyone who can pull the image.
    /// </remarks>
    public async Task<bool> BuildImageAsync(
        string tag,
        string dockerfile,
        string context,
        IReadOnlyDictionary<string, string> buildArgs,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "build", "-t", tag, "-f", dockerfile };

        foreach ((string key, string value) in buildArgs)
        {
            arguments.Add("--build-arg");
            arguments.Add($"{key}={value}");
        }

        arguments.Add(context);

        _logBus.Info("docker", $"building {tag} (this takes a while the first time, and only the first time)");

        ProcessResult result = await _processRunner.RunAsync(
            "docker", arguments, logSource: "docker", cancellationToken: cancellationToken).ConfigureAwait(false);

        if (result.Succeeded) _logBus.Info("docker", $"built {tag}");
        else _logBus.Error("docker", $"build of {tag} failed with exit code {result.ExitCode}");

        return result.Succeeded;
    }

    /// <summary>
    /// Starts one ephemeral runner container and hands it a JIT config.
    /// </summary>
    /// <remarks>
    /// The blob goes in on STDIN. It is never an argument: an argument list is
    /// readable from the host's process list by any user on the machine. The
    /// container takes one job and exits.
    /// </remarks>
    public async Task<ProcessResult> RunEphemeralAsync(
        string image,
        string containerName,
        JitConfig jitConfig,
        IReadOnlyDictionary<string, string> volumeMounts,
        string? cpuLimit,
        string? memoryLimit,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string>
        {
            "run", "--rm", "-i",
            "--name", containerName,
            // One job then gone, so a restart policy would be actively wrong.
            "--restart", "no",
        };

        foreach ((string source, string target) in volumeMounts)
        {
            arguments.Add("-v");
            arguments.Add($"{source}:{target}");
        }

        if (!string.IsNullOrWhiteSpace(cpuLimit)) { arguments.Add("--cpus"); arguments.Add(cpuLimit); }
        if (!string.IsNullOrWhiteSpace(memoryLimit)) { arguments.Add("--memory"); arguments.Add(memoryLimit); }

        // Capped so a runaway build cannot fill the disk with its own logs.
        arguments.Add("--log-opt"); arguments.Add("max-size=20m");
        arguments.Add("--log-opt"); arguments.Add("max-file=3");

        arguments.Add(image);

        _logBus.Info("docker", $"starting {containerName} from {image} (one job, then it dies)");

        return await _processRunner.RunAsync(
            "docker", arguments,
            standardInput: jitConfig.EncodedConfig,
            logSource: containerName,
            cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    public async Task<bool> EnsureVolumesAsync(CancellationToken cancellationToken = default)
    {
        bool allCreated = true;

        foreach (string volume in SweeperPolicy.KeepVolumes)
        {
            ProcessResult result = await _processRunner.RunAsync(
                "docker", ["volume", "create", volume],
                logSource: "docker", streamOutput: false, cancellationToken: cancellationToken).ConfigureAwait(false);

            if (!result.Succeeded)
            {
                _logBus.Error("docker", $"could not create volume {volume}: {result.CombinedOutput}");
                allCreated = false;
            }
        }

        return allCreated;
    }

    public async Task<IReadOnlyList<string>> ListContainersAsync(
        string? statusFilter = null, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "ps", "-a" };
        if (statusFilter is not null) { arguments.Add("--filter"); arguments.Add($"status={statusFilter}"); }
        arguments.Add("--format"); arguments.Add("{{.Names}}");

        ProcessResult result = await _processRunner.RunAsync(
            "docker", arguments, logSource: "docker", streamOutput: false, cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        return [.. result.StandardOutput.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)];
    }

    public async Task<bool> ImageExistsAsync(string tag, CancellationToken cancellationToken = default)
    {
        ProcessResult result = await _processRunner.RunAsync(
            "docker", ["image", "inspect", tag, "--format", "{{.Id}}"],
            logSource: "docker", streamOutput: false, cancellationToken: cancellationToken).ConfigureAwait(false);

        return result.Succeeded;
    }

    /// <summary>Free space on the drive holding Docker's data root.</summary>
    public async Task<long> GetFreeDiskBytesAsync(CancellationToken cancellationToken = default)
    {
        ProcessResult result = await _processRunner.RunAsync(
            "docker", ["info", "--format", "{{.DockerRootDir}}"],
            logSource: "docker", streamOutput: false, cancellationToken: cancellationToken).ConfigureAwait(false);

        string root = result.Succeeded ? result.StandardOutput.Trim() : Path.GetTempPath();
        if (string.IsNullOrWhiteSpace(root)) root = Path.GetTempPath();

        try
        {
            string? pathRoot = Path.GetPathRoot(Path.GetFullPath(root));
            if (string.IsNullOrEmpty(pathRoot)) return 0;
            return new DriveInfo(pathRoot).AvailableFreeSpace;
        }
        catch (Exception ex)
        {
            _logBus.Warning("docker", $"could not determine free space for {root}: {ex.Message}");
            return 0;
        }
    }
}
