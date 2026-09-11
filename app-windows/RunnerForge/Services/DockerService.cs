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

    /// <summary>Switches Docker Desktop to the Windows engine.</summary>
    public async Task<bool> SwitchToWindowsContainersAsync(CancellationToken cancellationToken = default)
    {
        string dockerCli = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "Docker", "Docker", "DockerCli.exe");

        if (!File.Exists(dockerCli))
        {
            _logBus.Error("docker", $"DockerCli.exe not found at {dockerCli}");
            return false;
        }

        ProcessResult result = await _processRunner.RunAsync(
            dockerCli, ["-SwitchWindowsEngine"], logSource: "docker", cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        return result.Succeeded;
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
