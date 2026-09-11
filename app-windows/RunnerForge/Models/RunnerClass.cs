namespace RunnerForge.Models;

/// <summary>
/// The five runner shapes Runner Forge knows how to host.
/// </summary>
/// <remarks>
/// The string values are the <c>classId</c> written to forge.json and consumed
/// by every script, so they are part of the on-disk contract and must not be
/// renamed casually.
/// </remarks>
public enum RunnerClassId
{
    WinBuild,
    LinuxUtil,
    MacBuild,
    WinIlok,
    MacIlok,
}

/// <summary>Where a runner of a given class actually executes.</summary>
public enum RunnerIsolation
{
    /// <summary>Windows container with Hyper-V isolation.</summary>
    WindowsContainer,

    /// <summary>Linux container.</summary>
    LinuxContainer,

    /// <summary>A throwaway Tart VM clone on macOS.</summary>
    TartVmClone,

    /// <summary>
    /// A plain host process. Used only by the iLok classes, because a container
    /// cannot see a USB device and there is no passthrough that changes that.
    /// </summary>
    HostProcess,
}

/// <summary>
/// The immutable facts about a runner class: its id, labels, host, isolation and
/// replica bounds. Everything here is fixed by the design, not by configuration.
/// </summary>
public sealed record RunnerClass
{
    public required RunnerClassId Id { get; init; }

    /// <summary>The <c>classId</c> string as it appears in forge.json.</summary>
    public required string ClassId { get; init; }

    public required string DisplayName { get; init; }

    public required RunnerIsolation Isolation { get; init; }

    /// <summary>Labels the ephemeral runner registers with, in order.</summary>
    public required IReadOnlyList<string> Labels { get; init; }

    public required int MinReplicas { get; init; }

    public required int MaxReplicas { get; init; }

    public required int DefaultReplicas { get; init; }

    /// <summary>True when this class runs on the Windows host.</summary>
    public required bool RunsOnWindows { get; init; }

    /// <summary>
    /// Why this class is not containerized, or null when it is. Shown in the UI
    /// so the design decision is visible rather than looking like an oversight.
    /// </summary>
    public string? NotContainerizedReason { get; init; }

    public bool IsIlok => Id is RunnerClassId.WinIlok or RunnerClassId.MacIlok;

    /// <summary>Replicas are fixed at 1 for the iLok classes: there is one dongle.</summary>
    public bool ReplicasAreFixed => IsIlok;

    // -----------------------------------------------------------------------
    // The canonical catalogue. These label sets are the contract with every
    // workflow's runs-on; changing one here without changing the workflow means
    // jobs queue forever against a runner that never appears.
    // -----------------------------------------------------------------------
    public static readonly RunnerClass WinBuild = new()
    {
        Id = RunnerClassId.WinBuild,
        ClassId = "win-build",
        DisplayName = "Windows build",
        Isolation = RunnerIsolation.WindowsContainer,
        Labels = ["self-hosted", "windows", "x64", "container", "forge"],
        MinReplicas = 1, MaxReplicas = 4, DefaultReplicas = 2,
        RunsOnWindows = true,
    };

    public static readonly RunnerClass LinuxUtil = new()
    {
        Id = RunnerClassId.LinuxUtil,
        ClassId = "linux-util",
        DisplayName = "Linux utility",
        Isolation = RunnerIsolation.LinuxContainer,
        Labels = ["self-hosted", "linux", "x64", "container", "forge"],
        MinReplicas = 1, MaxReplicas = 4, DefaultReplicas = 1,
        RunsOnWindows = true,
    };

    public static readonly RunnerClass MacBuild = new()
    {
        Id = RunnerClassId.MacBuild,
        ClassId = "mac-build",
        DisplayName = "macOS build",
        Isolation = RunnerIsolation.TartVmClone,
        Labels = ["self-hosted", "macos", "arm64", "tart", "forge"],
        MinReplicas = 1, MaxReplicas = 2, DefaultReplicas = 1,
        RunsOnWindows = false,
    };

    public static readonly RunnerClass WinIlok = new()
    {
        Id = RunnerClassId.WinIlok,
        ClassId = "win-ilok",
        DisplayName = "Windows iLok signing",
        Isolation = RunnerIsolation.HostProcess,
        Labels = ["self-hosted", "windows", "x64", "ilok", "forge"],
        MinReplicas = 1, MaxReplicas = 1, DefaultReplicas = 1,
        RunsOnWindows = true,
        NotContainerizedReason =
            "A Windows container cannot see a USB device. There is no passthrough, "
            + "no flag and no workaround, so the machine holding the dongle signs as a "
            + "host process. It deliberately has no compiler: a build job that could run "
            + "here could compromise the signing host.",
    };

    public static readonly RunnerClass MacIlok = new()
    {
        Id = RunnerClassId.MacIlok,
        ClassId = "mac-ilok",
        DisplayName = "macOS iLok signing",
        Isolation = RunnerIsolation.HostProcess,
        Labels = ["self-hosted", "macos", "arm64", "ilok", "forge"],
        MinReplicas = 1, MaxReplicas = 1, DefaultReplicas = 1,
        RunsOnWindows = false,
        NotContainerizedReason =
            "The dongle is a USB device and wraptool is a host tool, so this class "
            + "runs as a host process for the same reason win-ilok does. It deliberately "
            + "has no compiler.",
    };

    public static IReadOnlyList<RunnerClass> All { get; } =
        [WinBuild, LinuxUtil, MacBuild, WinIlok, MacIlok];

    public static RunnerClass FromClassId(string classId) =>
        All.FirstOrDefault(c => c.ClassId == classId)
        ?? throw new ArgumentOutOfRangeException(nameof(classId), classId, "Unknown runner class id.");
}
