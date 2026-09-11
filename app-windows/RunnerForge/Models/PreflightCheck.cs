namespace RunnerForge.Models;

/// <summary>Outcome of one preflight check.</summary>
public enum PreflightStatus
{
    Checking,
    Pass,

    /// <summary>Not met, but only some runner classes are affected.</summary>
    Warn,

    /// <summary>Not met, and the affected classes cannot run at all.</summary>
    Fail,
}

/// <summary>
/// One row on the Preflight page: what was checked, what was found, and whether
/// Runner Forge can fix it.
/// </summary>
public sealed record PreflightCheck
{
    public required string Name { get; init; }

    public required PreflightStatus Status { get; init; }

    /// <summary>What was actually found. Concrete, not "something went wrong".</summary>
    public required string Detail { get; init; }

    /// <summary>What the user (or the Fix button) should do. Null when nothing to do.</summary>
    public string? FixHint { get; init; }

    /// <summary>True when the Fix button can resolve this without the user leaving the app.</summary>
    public bool AutoFixable { get; init; }

    /// <summary>Runner classes this check blocks, by classId. Empty when it blocks nothing.</summary>
    public IReadOnlyList<string> BlocksClasses { get; init; } = [];

    /// <summary>
    /// True when this failure has no workaround at all — Windows Home, or an
    /// Intel Mac. The UI states the reason rather than offering a Fix that
    /// cannot work.
    /// </summary>
    public bool IsHardBlock { get; init; }

    public bool RequiresReboot { get; init; }
}
