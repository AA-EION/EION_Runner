using System.Management;
using System.Net.Http;
using System.Runtime.Versioning;
using RunnerForge.Models;

namespace RunnerForge.Services;

/// <summary>
/// Says exactly what is missing on this machine, and fixes what it can.
/// </summary>
/// <remarks>
/// Windows Home is a HARD BLOCK with no workaround: Windows containers need
/// Hyper-V isolation, which Home does not provide. Saying so here is far kinder
/// than letting the user find out three failed builds later.
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class PreflightService(
    LogBus logBus, ProcessRunner processRunner, DockerService dockerService, HttpClient httpClient)
{
    private readonly LogBus _logBus = logBus;
    private readonly ProcessRunner _processRunner = processRunner;
    private readonly DockerService _dockerService = dockerService;
    private readonly HttpClient _httpClient = httpClient;

    public const int MinimumWindowsBuild = 22000;
    public const string MinimumDockerDesktop = "4.37.0";

    public async Task<IReadOnlyList<PreflightCheck>> RunAllAsync(
        ForgeConfig config, CancellationToken cancellationToken = default)
    {
        var checks = new List<PreflightCheck>
        {
            CheckWindowsEdition(),
            CheckBuildNumber(),
            CheckVirtualization(),
        };

        checks.AddRange(CheckWindowsFeatures());

        DockerStatus docker = await _dockerService.GetStatusAsync(cancellationToken).ConfigureAwait(false);
        checks.Add(CheckDockerInstalled(docker));
        checks.Add(CheckDockerDaemon(docker));
        checks.Add(CheckWindowsContainerMode(docker));
        checks.Add(await CheckWslAsync(cancellationToken).ConfigureAwait(false));
        checks.Add(await CheckFreeDiskAsync(config, cancellationToken).ConfigureAwait(false));
        checks.Add(await CheckSleepOnAcAsync(cancellationToken).ConfigureAwait(false));

        foreach (string endpoint in new[] { "github.com", "api.github.com", "ghcr.io", "mcr.microsoft.com" })
        {
            checks.Add(await CheckEndpointAsync(endpoint, cancellationToken).ConfigureAwait(false));
        }

        checks.Add(await CheckBaseImagesAsync(cancellationToken).ConfigureAwait(false));

        if (config.Signing.ModeEnum == SigningMode.WindowsIlok)
        {
            checks.AddRange(CheckIlok());
        }
        else
        {
            checks.Add(new PreflightCheck
            {
                Name = "iLok checks",
                Status = PreflightStatus.Pass,
                Detail = $"skipped: signing mode is '{config.Signing.Mode}', which needs no dongle on this host",
            });
        }

        return checks;
    }

    private PreflightCheck CheckWindowsEdition()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT Caption FROM Win32_OperatingSystem");
            string caption = searcher.Get().Cast<ManagementObject>()
                .Select(o => o["Caption"]?.ToString() ?? "").FirstOrDefault() ?? "";

            if (caption.Contains("Home", StringComparison.OrdinalIgnoreCase))
            {
                return new PreflightCheck
                {
                    Name = "Windows edition",
                    Status = PreflightStatus.Fail,
                    Detail = caption + ". Windows containers require Hyper-V isolation, which Home does not "
                             + "provide. There is no supported workaround: not WSL, not process isolation, "
                             + "not a third-party shim.",
                    FixHint = "Upgrade to Windows 11 Pro or Enterprise.",
                    IsHardBlock = true,
                    BlocksClasses = ["win-build"],
                };
            }

            return new PreflightCheck { Name = "Windows edition", Status = PreflightStatus.Pass, Detail = caption };
        }
        catch (Exception ex)
        {
            return Warn("Windows edition", $"could not determine the edition: {ex.Message}");
        }
    }

    private PreflightCheck CheckBuildNumber()
    {
        int build = Environment.OSVersion.Version.Build;
        return build >= MinimumWindowsBuild
            ? new PreflightCheck { Name = "Windows build number", Status = PreflightStatus.Pass,
                                   Detail = $"build {build} (minimum {MinimumWindowsBuild})" }
            : new PreflightCheck { Name = "Windows build number", Status = PreflightStatus.Fail,
                                   Detail = $"build {build} is below the minimum {MinimumWindowsBuild} "
                                            + "required for ltsc2022 container compatibility.",
                                   FixHint = "Install the latest Windows feature update.",
                                   BlocksClasses = ["win-build"] };
    }

    private PreflightCheck CheckVirtualization()
    {
        try
        {
            // ---------------------------------------------------------------
            // ASK WHETHER A HYPERVISOR IS RUNNING BEFORE ASKING THE CPU.
            //
            // Win32_Processor.VirtualizationFirmwareEnabled reports FALSE once
            // Hyper-V is running, because the hypervisor has already claimed
            // VT-x and the host OS no longer sees the firmware flag. Reading it
            // alone therefore declares "virtualization is disabled in firmware"
            // on a machine that is at that moment running Hyper-V, WSL2 and
            // Docker — which is exactly what it did, as a HARD BLOCK saying the
            // problem "cannot be changed from Windows".
            //
            // If a hypervisor is present then virtualization is working, by
            // definition and by demonstration. That answer comes first.
            // ---------------------------------------------------------------
            using (var system = new ManagementObjectSearcher(
                "SELECT HypervisorPresent FROM Win32_ComputerSystem"))
            {
                foreach (ManagementObject box in system.Get().Cast<ManagementObject>())
                {
                    if (box["HypervisorPresent"] as bool? == true)
                    {
                        return new PreflightCheck
                        {
                            Name = "Hardware virtualization",
                            Status = PreflightStatus.Pass,
                            Detail = "a hypervisor is running, so virtualization is enabled and in use",
                        };
                    }
                }
            }

            using var searcher = new ManagementObjectSearcher(
                "SELECT VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions FROM Win32_Processor");

            foreach (ManagementObject cpu in searcher.Get().Cast<ManagementObject>())
            {
                bool firmware = cpu["VirtualizationFirmwareEnabled"] as bool? ?? false;
                bool slat = cpu["SecondLevelAddressTranslationExtensions"] as bool? ?? false;
                if (firmware || slat)
                {
                    return new PreflightCheck { Name = "Hardware virtualization",
                                                Status = PreflightStatus.Pass, Detail = "enabled in firmware" };
                }
            }

            return new PreflightCheck
            {
                Name = "Hardware virtualization",
                Status = PreflightStatus.Fail,
                Detail = "Virtualization is disabled in firmware. Hyper-V cannot start without it.",
                FixHint = "Enable Intel VT-x / AMD-V in your UEFI firmware settings. "
                          + "This cannot be changed from Windows.",
                IsHardBlock = true,
                BlocksClasses = ["win-build", "linux-util"],
            };
        }
        catch (Exception ex)
        {
            return Warn("Hardware virtualization", $"could not query the CPU: {ex.Message}");
        }
    }

    private IEnumerable<PreflightCheck> CheckWindowsFeatures()
    {
        foreach (string feature in new[] { "Microsoft-Hyper-V", "Containers" })
        {
            bool enabled = IsFeatureEnabled(feature);
            yield return enabled
                ? new PreflightCheck { Name = $"Windows feature: {feature}",
                                       Status = PreflightStatus.Pass, Detail = "enabled" }
                : new PreflightCheck { Name = $"Windows feature: {feature}",
                                       Status = PreflightStatus.Fail, Detail = "not enabled",
                                       FixHint = $"dism.exe /Online /Enable-Feature /FeatureName:{feature} "
                                                 + "/All /NoRestart, then reboot",
                                       AutoFixable = true, RequiresReboot = true,
                                       BlocksClasses = ["win-build"] };
        }
    }

    private static bool IsFeatureEnabled(string feature)
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(
                $"SELECT InstallState FROM Win32_OptionalFeature WHERE Name = '{feature}'");
            foreach (ManagementObject item in searcher.Get().Cast<ManagementObject>())
            {
                // InstallState 1 == Enabled.
                if (Convert.ToInt32(item["InstallState"]) == 1) return true;
            }
        }
        catch (Exception) { }
        return false;
    }

    /// <summary>Enables a Windows feature via DISM. Never reboots on its own.</summary>
    public async Task<bool> EnableFeatureAsync(string feature, CancellationToken cancellationToken = default)
    {
        ProcessResult result = await _processRunner.RunAsync(
            "dism.exe", ["/Online", "/Enable-Feature", $"/FeatureName:{feature}", "/All", "/NoRestart"],
            logSource: "preflight", cancellationToken: cancellationToken).ConfigureAwait(false);

        if (result.Succeeded) _logBus.Info("preflight", $"{feature} enabled; a REBOOT is required");
        return result.Succeeded;
    }

    private static PreflightCheck CheckDockerInstalled(DockerStatus status) =>
        !status.CliPresent
            ? new PreflightCheck { Name = "Docker Desktop installed", Status = PreflightStatus.Fail,
                                   Detail = "docker is not on PATH.",
                                   FixHint = $"Install Docker Desktop {MinimumDockerDesktop} or newer.",
                                   BlocksClasses = ["win-build", "linux-util"] }
            : new PreflightCheck { Name = "Docker Desktop installed", Status = PreflightStatus.Pass,
                                   Detail = $"server {status.Version ?? "(not reported)"}" };

    private static PreflightCheck CheckDockerDaemon(DockerStatus status) =>
        status.DaemonReachable
            ? new PreflightCheck { Name = "Docker daemon reachable", Status = PreflightStatus.Pass,
                                   Detail = "the daemon is answering" }
            : new PreflightCheck { Name = "Docker daemon reachable", Status = PreflightStatus.Fail,
                                   Detail = "docker is installed but the daemon is not answering.",
                                   FixHint = "Start Docker Desktop and wait for the whale icon to stop "
                                             + "animating. If it never settles, check "
                                             + @"%LOCALAPPDATA%\Docker\log.txt.",
                                   BlocksClasses = ["win-build", "linux-util"] };

    private static PreflightCheck CheckWindowsContainerMode(DockerStatus status)
    {
        if (!status.DaemonReachable)
        {
            return new PreflightCheck { Name = "Docker in Windows containers mode",
                                        Status = PreflightStatus.Warn,
                                        Detail = "cannot tell: the daemon is not answering" };
        }

        return status.OsType == "windows"
            ? new PreflightCheck { Name = "Docker in Windows containers mode",
                                   Status = PreflightStatus.Pass, Detail = "OSType=windows" }
            : new PreflightCheck { Name = "Docker in Windows containers mode",
                                   Status = PreflightStatus.Fail,
                                   Detail = $"OSType={status.OsType}. win-build is a Windows container and "
                                            + "cannot run on the Linux engine.",
                                   FixHint = @"""%ProgramFiles%\Docker\Docker\DockerCli.exe"" -SwitchWindowsEngine",
                                   AutoFixable = true, BlocksClasses = ["win-build"] };
    }

    private async Task<PreflightCheck> CheckWslAsync(CancellationToken cancellationToken)
    {
        if (!ProcessRunner.IsOnPath("wsl"))
        {
            return new PreflightCheck { Name = "WSL2 with a distribution", Status = PreflightStatus.Warn,
                                        Detail = "wsl is not on PATH. Only linux-util is affected.",
                                        FixHint = "wsl --install", BlocksClasses = ["linux-util"] };
        }

        ProcessResult result = await _processRunner.RunAsync(
            "wsl", ["--list", "--quiet"], logSource: "preflight", streamOutput: false,
            cancellationToken: cancellationToken).ConfigureAwait(false);

        // wsl.exe emits UTF-16, which arrives with embedded nulls.
        string[] distros = result.StandardOutput.Replace("\0", "")
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        return distros.Length > 0
            ? new PreflightCheck { Name = "WSL2 with a distribution", Status = PreflightStatus.Pass,
                                   Detail = $"{distros.Length} distribution(s) installed" }
            : new PreflightCheck { Name = "WSL2 with a distribution", Status = PreflightStatus.Warn,
                                   Detail = "WSL is present but no distribution is installed. "
                                            + "Only linux-util is affected.",
                                   FixHint = "wsl --install -d Ubuntu", BlocksClasses = ["linux-util"] };
    }

    private async Task<PreflightCheck> CheckFreeDiskAsync(ForgeConfig config, CancellationToken cancellationToken)
    {
        long freeBytes = await _dockerService.GetFreeDiskBytesAsync(cancellationToken).ConfigureAwait(false);
        double freeGb = freeBytes / 1024.0 / 1024 / 1024;

        return freeGb >= config.Limits.MaxDiskGb
            ? new PreflightCheck { Name = "Free disk space", Status = PreflightStatus.Pass,
                                   Detail = $"{freeGb:0.#} GB free (minimum {config.Limits.MaxDiskGb} GB)" }
            : new PreflightCheck { Name = "Free disk space", Status = PreflightStatus.Fail,
                                   Detail = $"{freeGb:0.#} GB free, below the configured minimum of "
                                            + $"{config.Limits.MaxDiskGb} GB. The Windows image alone is several GB.",
                                   FixHint = "Free space, or lower limits.maxDiskGb in forge.json.",
                                   BlocksClasses = ["win-build", "linux-util"] };
    }

    private async Task<PreflightCheck> CheckSleepOnAcAsync(CancellationToken cancellationToken)
    {
        ProcessResult result = await _processRunner.RunAsync(
            "powercfg", ["/query", "SCHEME_CURRENT", "SUB_SLEEP", "STANDBYIDLE"],
            logSource: "preflight", streamOutput: false, cancellationToken: cancellationToken).ConfigureAwait(false);

        bool never = result.StandardOutput.Contains("Current AC Power Setting Index: 0x00000000",
                                                    StringComparison.OrdinalIgnoreCase);

        return never
            ? new PreflightCheck { Name = "Sleep on AC disabled", Status = PreflightStatus.Pass,
                                   Detail = "standby timeout on AC is 0 (never)" }
            : new PreflightCheck { Name = "Sleep on AC disabled", Status = PreflightStatus.Warn,
                                   Detail = "This machine can sleep on AC power. A sleeping host drops "
                                            + "in-flight jobs.",
                                   FixHint = "powercfg /change standby-timeout-ac 0", AutoFixable = true };
    }

    public async Task<bool> DisableSleepOnAcAsync(CancellationToken cancellationToken = default)
    {
        ProcessResult result = await _processRunner.RunAsync(
            "powercfg", ["/change", "standby-timeout-ac", "0"],
            logSource: "preflight", cancellationToken: cancellationToken).ConfigureAwait(false);
        return result.Succeeded;
    }

    private async Task<PreflightCheck> CheckEndpointAsync(string endpoint, CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Head, $"https://{endpoint}");
            using HttpResponseMessage response =
                await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);

            // A 4xx still proves reachability; only a transport failure matters.
            return new PreflightCheck { Name = $"Outbound HTTPS: {endpoint}", Status = PreflightStatus.Pass,
                                        Detail = $"HTTP {(int)response.StatusCode} (reachable)" };
        }
        catch (Exception ex)
        {
            return new PreflightCheck { Name = $"Outbound HTTPS: {endpoint}", Status = PreflightStatus.Fail,
                                        Detail = $"unreachable: {ex.Message}",
                                        FixHint = "Check your firewall, proxy, or corporate TLS "
                                                  + "inspection settings.",
                                        BlocksClasses = ["win-build", "linux-util", "win-ilok"] };
        }
    }

    private async Task<PreflightCheck> CheckBaseImagesAsync(CancellationToken cancellationToken)
    {
        bool win = await _dockerService.ImageExistsAsync("runnerforge/win-build:1.0.0", cancellationToken)
            .ConfigureAwait(false);
        bool linux = await _dockerService.ImageExistsAsync("runnerforge/linux-util:1.0.0", cancellationToken)
            .ConfigureAwait(false);

        return win && linux
            ? new PreflightCheck { Name = "Base images built", Status = PreflightStatus.Pass,
                                   Detail = "win-build and linux-util are present" }
            : new PreflightCheck { Name = "Base images built", Status = PreflightStatus.Warn,
                                   Detail = $"win-build: {(win ? "present" : "missing")}, "
                                            + $"linux-util: {(linux ? "present" : "missing")}. "
                                            + "Informational: the first build takes a while but only happens once.",
                                   FixHint = "Use \"Rebuild image\" on the Runners page.", AutoFixable = true };
    }

    private IEnumerable<PreflightCheck> CheckIlok()
    {
        bool driver = Directory.Exists(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "PACE"));

        yield return driver
            ? new PreflightCheck { Name = "iLok driver", Status = PreflightStatus.Pass,
                                   Detail = "PACE support files present" }
            : new PreflightCheck { Name = "iLok driver", Status = PreflightStatus.Fail,
                                   Detail = "The PACE License Services driver is not installed.",
                                   FixHint = "Install iLok License Manager, which installs the driver.",
                                   BlocksClasses = ["win-ilok"] };

        bool dongle = false;
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT Name, PNPDeviceID FROM Win32_PnPEntity");
            dongle = searcher.Get().Cast<ManagementObject>().Any(device =>
                (device["Name"]?.ToString() ?? "").Contains("iLok", StringComparison.OrdinalIgnoreCase)
                || (device["PNPDeviceID"]?.ToString() ?? "").Contains("VID_088E", StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception) { }

        yield return dongle
            ? new PreflightCheck { Name = "iLok dongle detected", Status = PreflightStatus.Pass,
                                   Detail = "an iLok USB device is attached" }
            : new PreflightCheck { Name = "iLok dongle detected", Status = PreflightStatus.Fail,
                                   Detail = "No iLok USB device found. Note that a Windows container can NEVER "
                                            + "see one; win-ilok is deliberately a host process for exactly "
                                            + "this reason.",
                                   FixHint = "Plug the dongle into this machine, or switch signing mode to Cloud.",
                                   BlocksClasses = ["win-ilok"] };

        // The PACE installer does NOT put wraptool on PATH, so asking PATH
        // reports "missing" on a machine where it is installed and working.
        // Use the same discovery the Signing page and the signing scripts use —
        // the WRAPTOOL override, then PATH, then the versioned SDK install
        // path — so the two pages cannot disagree about whether it is there.
        string? wraptool = SigningService.FindWraptool();
        yield return wraptool is not null
            ? new PreflightCheck { Name = "wraptool available", Status = PreflightStatus.Pass,
                                   Detail = wraptool }
            : new PreflightCheck { Name = "wraptool available", Status = PreflightStatus.Fail,
                                   Detail = "wraptool.exe was not found on PATH, at the PACE Fusion SDK "
                                            + "install path, or via the WRAPTOOL environment variable.",
                                   FixHint = "Install the PACE Fusion SDK (it ships wraptool under "
                                             + @"PACEAntiPiracy\Eden\Fusion\Versions\<version>\bin), "
                                             + "or set WRAPTOOL to its full path.",
                                   BlocksClasses = ["win-ilok"] };
    }

    private static PreflightCheck Warn(string name, string detail) =>
        new() { Name = name, Status = PreflightStatus.Warn, Detail = detail };
}
