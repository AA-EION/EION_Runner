using RunnerForge.Services;
using Xunit;

namespace RunnerForge.Tests;

/// <summary>
/// The Sweeper's policy, proven without a disk or a Docker daemon.
/// </summary>
/// <remarks>
/// Erring in either direction is a bug: deleting a KEEP item makes the next
/// build re-clone JUCE and re-pull a multi-gigabyte base image, while keeping a
/// PURGE item fills the disk until the machine stops building.
/// </remarks>
public sealed class SweeperPolicyTests
{
    private const string WindowsTag = "1.0.0";
    private const string LinuxTag = "1.0.0";

    [Theory]
    [InlineData("forge-fetchcontent")]
    [InlineData("forge-sccache")]
    [InlineData("forge-ccache")]
    [InlineData("forge-aax-sdk")]
    public void Every_cache_volume_is_a_keep_item(string volume)
    {
        Assert.Contains(volume, SweeperPolicy.KeepVolumes);
        Assert.True(SweeperPolicy.IsKeepItem(volume, WindowsTag, LinuxTag));
    }

    [Theory]
    [InlineData("runnerforge/win-build:1.0.0")]
    [InlineData("runnerforge/linux-util:1.0.0")]
    [InlineData("mcr.microsoft.com/windows/servercore:ltsc2022")]
    [InlineData("ubuntu:24.04")]
    public void Every_tagged_base_image_is_a_keep_item(string tag)
    {
        Assert.True(SweeperPolicy.IsKeepItem(tag, WindowsTag, LinuxTag));
    }

    [Fact]
    public void The_provisioned_tart_image_is_a_keep_item()
    {
        Assert.True(SweeperPolicy.IsKeepItem("runnerforge-macos:1.0.0", WindowsTag, LinuxTag));
        Assert.True(SweeperPolicy.IsKeepItem(
            "ghcr.io/cirruslabs/macos-tahoe-xcode:26", WindowsTag, LinuxTag));
    }

    /// <summary>
    /// The single most destructive mistake this product could make. `system
    /// prune -a` deletes tagged images, which is exactly what the KEEP list
    /// exists to prevent.
    /// </summary>
    [Theory]
    [InlineData("docker system prune -a")]
    [InlineData("docker system prune")]
    [InlineData("docker system prune -a -f --volumes")]
    [InlineData("docker image prune -a -f")]
    public void Prune_commands_that_would_destroy_keep_items_are_forbidden(string command)
    {
        Assert.True(SweeperPolicy.IsForbiddenPrune(command));
    }

    [Theory]
    [InlineData("docker image prune -f")]
    [InlineData("docker builder prune -f")]
    public void Targeted_prunes_are_allowed(string command)
    {
        Assert.False(SweeperPolicy.IsForbiddenPrune(command));
        Assert.Contains(command, SweeperPolicy.AllowedPruneCommands);
    }

    [Fact]
    public void No_allowed_prune_command_is_itself_forbidden()
    {
        // Guards against the allow-list and the deny-list drifting apart.
        Assert.All(SweeperPolicy.AllowedPruneCommands,
            command => Assert.False(SweeperPolicy.IsForbiddenPrune(command)));
    }

    /// <summary>
    /// Only CLONES may be deleted. Deleting a Tart IMAGE destroys tens of
    /// gigabytes that take about an hour to rebuild.
    /// </summary>
    [Theory]
    [InlineData("forge-mac-a1b2c3d4", true)]
    [InlineData("forge-mac-00000000", true)]
    [InlineData("runnerforge-macos:1.0.0", false)]
    [InlineData("ghcr.io/cirruslabs/macos-tahoe-xcode:26", false)]
    public void Only_tart_clones_may_be_deleted(string name, bool deletable)
    {
        Assert.Equal(deletable, SweeperPolicy.IsDeletableTartEntry(name));
    }

    [Fact]
    public void A_keep_volume_is_never_also_a_purge_directory()
    {
        foreach (string volume in SweeperPolicy.KeepVolumes)
        {
            Assert.DoesNotContain(SweeperPolicy.PurgeDirectories, d => d.Relative == volume);
        }
    }

    [Theory]
    [InlineData("jobs")]
    [InlineData("tmp")]
    public void Ephemeral_work_directories_are_purged(string relative)
    {
        Assert.Contains(SweeperPolicy.PurgeDirectories, d => d.Relative == relative);
    }

    /// <summary>
    /// The cache directory is what makes run 2 faster than run 1. Purging it
    /// would silently undo the entire caching design.
    /// </summary>
    [Fact]
    public void The_cache_directory_is_never_purged()
    {
        Assert.DoesNotContain(SweeperPolicy.PurgeDirectories, d => d.Relative == "cache");
    }

    [Theory]
    [InlineData("exited")]
    [InlineData("created")]
    [InlineData("dead")]
    public void Stopped_container_states_are_purgeable(string state)
    {
        Assert.Contains(state, SweeperPolicy.PurgeContainerStates);
    }

    [Fact]
    public void A_running_container_is_never_purgeable()
    {
        Assert.DoesNotContain("running", SweeperPolicy.PurgeContainerStates);
        Assert.DoesNotContain("paused", SweeperPolicy.PurgeContainerStates);
    }

    [Fact]
    public void Nothing_on_the_keep_list_is_reachable_through_a_deletable_tart_entry()
    {
        foreach (string tag in SweeperPolicy.KeepImageTags(WindowsTag, LinuxTag))
        {
            Assert.False(SweeperPolicy.IsDeletableTartEntry(tag));
        }
    }
}
