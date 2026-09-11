namespace RunnerForge.Models;

/// <summary>Which side of the Cleanup page an item belongs to.</summary>
public enum DiskCategory
{
    /// <summary>Never deleted. Deleting it is what makes the next run slow.</summary>
    Keep,

    /// <summary>Deleted on close and on demand.</summary>
    Purge,
}

/// <summary>One row on the Cleanup page.</summary>
public sealed record DiskUsageItem
{
    public required string Description { get; init; }
    public required DiskCategory Category { get; init; }
    public required long Bytes { get; init; }

    /// <summary>Why this item is kept, shown so KEEP does not look like clutter.</summary>
    public string? Reason { get; init; }

    public string HumanBytes => FormatBytes(Bytes);

    public static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = bytes;
        int unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return unit == 0 ? $"{bytes} B" : $"{value:0.#} {units[unit]}";
    }
}

/// <summary>The Cleanup page's whole model: two explicit lists and a total.</summary>
public sealed record DiskUsage
{
    public IReadOnlyList<DiskUsageItem> Keep { get; init; } = [];
    public IReadOnlyList<DiskUsageItem> Purge { get; init; } = [];

    public long KeepBytes => Keep.Sum(i => i.Bytes);
    public long ReclaimableBytes => Purge.Sum(i => i.Bytes);

    public string HumanKeepBytes => DiskUsageItem.FormatBytes(KeepBytes);
    public string HumanReclaimableBytes => DiskUsageItem.FormatBytes(ReclaimableBytes);
}
