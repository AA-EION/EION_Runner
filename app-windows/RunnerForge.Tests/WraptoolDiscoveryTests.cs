using System.Runtime.Versioning;
using RunnerForge.Services;
using Xunit;

namespace RunnerForge.Tests;

/// <summary>
/// wraptool discovery, which two pages have to agree about.
/// </summary>
/// <remarks>
/// The Preflight page reported "wraptool.exe is not on PATH" on a machine where
/// the PACE Fusion SDK was installed and the Signing page found wraptool
/// perfectly well — because Preflight asked PATH and Signing asked the SDK
/// install path. The PACE installer does not add itself to PATH, so PATH is the
/// wrong question. Both now call FindWraptool.
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class WraptoolDiscoveryTests
{
    [Fact]
    public void The_WRAPTOOL_override_is_honoured_when_it_points_at_a_real_file()
    {
        string fake = Path.Combine(Path.GetTempPath(), $"rf-wraptool-{Guid.NewGuid():N}.exe");
        File.WriteAllText(fake, "not really wraptool");

        string? before = Environment.GetEnvironmentVariable("WRAPTOOL");
        try
        {
            Environment.SetEnvironmentVariable("WRAPTOOL", fake);
            Assert.Equal(fake, SigningService.FindWraptool());
        }
        finally
        {
            Environment.SetEnvironmentVariable("WRAPTOOL", before);
            File.Delete(fake);
        }
    }

    [Fact]
    public void An_override_pointing_at_nothing_is_ignored_rather_than_returned()
    {
        // Returning a path that does not exist would turn "not installed" into a
        // confusing failure deep inside a signing run.
        string missing = Path.Combine(Path.GetTempPath(), $"rf-absent-{Guid.NewGuid():N}.exe");

        string? before = Environment.GetEnvironmentVariable("WRAPTOOL");
        try
        {
            Environment.SetEnvironmentVariable("WRAPTOOL", missing);
            Assert.NotEqual(missing, SigningService.FindWraptool());
        }
        finally
        {
            Environment.SetEnvironmentVariable("WRAPTOOL", before);
        }
    }

    [Fact]
    public void Discovery_never_depends_on_wraptool_being_on_PATH_alone()
    {
        // The regression in one sentence: PATH is not where the PACE installer
        // puts wraptool, so a PATH-only check reports missing on a working
        // machine. Asserted on the observable contract — an override that PATH
        // knows nothing about still resolves.
        string fake = Path.Combine(Path.GetTempPath(), $"rf-offpath-{Guid.NewGuid():N}.exe");
        File.WriteAllText(fake, "x");

        string? before = Environment.GetEnvironmentVariable("WRAPTOOL");
        try
        {
            Environment.SetEnvironmentVariable("WRAPTOOL", fake);

            Assert.False(ProcessRunner.IsOnPath(Path.GetFileNameWithoutExtension(fake)));
            Assert.NotNull(SigningService.FindWraptool());
        }
        finally
        {
            Environment.SetEnvironmentVariable("WRAPTOOL", before);
            File.Delete(fake);
        }
    }
}
