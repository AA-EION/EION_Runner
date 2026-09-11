using RunnerForge.Models;
using RunnerForge.Services;
using Xunit;

namespace RunnerForge.Tests;

/// <summary>
/// The two container engines, and the rule that follows from Docker Desktop
/// pointing its CLI at exactly one of them at a time.
/// </summary>
/// <remarks>
/// The original design demanded a machine-wide "Windows containers mode",
/// offered a Fix that switched the whole machine to it, and blocked win-build
/// until you did. That Fix broke linux-util on the same machine, which needs the
/// engine it switched away from — and the app declares BOTH classes as running
/// on Windows.
///
/// What is actually true: switching the endpoint does not stop containers that
/// are already running. Both classes can be up at once; they simply cannot be
/// started, or inspected, through one endpoint at one moment. So the engine is
/// chosen per operation, and anything that enumerates containers must visit
/// both.
/// </remarks>
public sealed class ContainerEngineTests
{
    private static ForgeConfig WithEnabled(params string[] classIds)
    {
        ForgeConfig config = ForgeConfig.CreateDefault(@"C:\ProgramData\RunnerForge\work");
        foreach (RunnerConfig runner in config.Runners)
        {
            runner.Enabled = classIds.Contains(runner.ClassId);
        }
        return config;
    }

    [Fact]
    public void The_two_windows_hosted_container_classes_need_different_engines()
    {
        RunnerClass winBuild = RunnerClass.All.Single(c => c.ClassId == "win-build");
        RunnerClass linuxUtil = RunnerClass.All.Single(c => c.ClassId == "linux-util");

        // Both are declared as running on the same Windows machine...
        Assert.True(winBuild.RunsOnWindows);
        Assert.True(linuxUtil.RunsOnWindows);

        // ...while needing different daemons. That combination is the whole
        // reason a single machine-wide engine mode was the wrong model.
        Assert.Equal(RunnerIsolation.WindowsContainer, winBuild.Isolation);
        Assert.Equal(RunnerIsolation.LinuxContainer, linuxUtil.Isolation);
        Assert.NotEqual(winBuild.Isolation, linuxUtil.Isolation);
    }

    [Fact]
    public void A_machine_running_both_kinds_must_have_both_engines_reaped()
    {
        ForgeConfig config = WithEnabled("win-build", "linux-util");

        bool windows = config.Runners.Any(r => r.Enabled && RunnerClass.All.Any(
            c => c.ClassId == r.ClassId && c.Isolation == RunnerIsolation.WindowsContainer));
        bool linux = config.Runners.Any(r => r.Enabled && RunnerClass.All.Any(
            c => c.ClassId == r.ClassId && c.Isolation == RunnerIsolation.LinuxContainer));

        // A reap that visits only one of these reports "clean" while the other
        // holds a live runner still registered with GitHub.
        Assert.True(windows);
        Assert.True(linux);
    }

    [Fact]
    public void A_machine_running_only_linux_containers_needs_no_windows_engine_scan()
    {
        ForgeConfig config = WithEnabled("linux-util");

        bool windows = config.Runners.Any(r => r.Enabled && RunnerClass.All.Any(
            c => c.ClassId == r.ClassId && c.Isolation == RunnerIsolation.WindowsContainer));

        // Switching engines costs seconds. Paying it on every reap of a
        // Linux-only machine would slow closing the app down for nothing.
        Assert.False(windows);
    }

    [Fact]
    public void A_stray_container_records_the_engine_that_holds_it()
    {
        // `docker rm` only reaches the selected daemon, so a stray that does not
        // know its engine cannot reliably be removed.
        var stray = new Stray(
            "container", "forge-linux-util-0", null, "detail", DockerService.DockerEngine.Linux);

        Assert.Equal(DockerService.DockerEngine.Linux, stray.Engine);

        // Process strays legitimately have none.
        var process = new Stray("process", "MSBuild", 1234, "detail");
        Assert.Null(process.Engine);
    }
}
