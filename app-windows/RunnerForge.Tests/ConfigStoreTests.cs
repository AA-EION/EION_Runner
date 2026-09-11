using System.Text.Json;
using System.Text.Json.Nodes;
using RunnerForge.Models;
using RunnerForge.Services;
using Xunit;

namespace RunnerForge.Tests;

/// <summary>
/// The config contract. These assert the rules that keep forge.json safe and
/// loadable — above all that a secret can never be persisted into it.
/// </summary>
public sealed class ConfigStoreTests
{
    private static JsonNode Parse(string json) => JsonNode.Parse(json)!;

    private static ForgeConfig ValidConfig()
    {
        ForgeConfig config = ForgeConfig.CreateDefault(@"C:\ProgramData\RunnerForge\work");
        config.GitHub.Owner = "AA-EION";
        config.GitHub.Repos = ["RecRoll"];
        config.GitHub.AppId = "1234567";
        config.GitHub.InstallationId = "87654321";
        return config;
    }

    private static JsonNode ValidNode() =>
        Parse(JsonSerializer.Serialize(ValidConfig(), ForgeConfig.SerializerOptions));

    /// <summary>
    /// The failure this guards against killed the app with no window and no
    /// error message: Save() threw out of Load(), out of the service container,
    /// and out of OnStartup before any handler was attached. Starting with a
    /// per-user config beats not starting.
    /// </summary>
    [Fact]
    public void An_unwritable_machine_config_falls_back_to_the_user_config()
    {
        // A path whose PARENT is an existing file. Directory.CreateDirectory
        // cannot make a directory there, so Save() throws IOException — the
        // same shape as the ACL failure this exists for, without needing to
        // manipulate ACLs in a test.
        string blocker = Path.Combine(Path.GetTempPath(), $"rf-blocker-{Guid.NewGuid():N}");
        File.WriteAllText(blocker, "not a directory");

        string fallback = ConfigStore.FallbackConfigPath;
        string? saved = File.Exists(fallback) ? File.ReadAllText(fallback) : null;

        try
        {
            var store = new ConfigStore(new LogBus())
            {
                ConfigPath = Path.Combine(blocker, "RunnerForge", "forge.json"),
            };

            ForgeConfig config = store.Load();

            Assert.NotNull(config);
            Assert.Equal(fallback, store.ConfigPath);
            Assert.True(File.Exists(fallback));
        }
        finally
        {
            File.Delete(blocker);
            if (saved is null) File.Delete(fallback);
            else File.WriteAllText(fallback, saved);
        }
    }

    [Fact]
    public void A_valid_config_produces_no_problems()
    {
        Assert.Empty(ConfigStore.Validate(ValidNode()));
    }

    [Fact]
    public void Schema_version_must_be_one()
    {
        JsonNode node = ValidNode();
        node["schemaVersion"] = 2;

        Assert.Contains(ConfigStore.Validate(node), p => p.StartsWith("/schemaVersion", StringComparison.Ordinal));
    }

    /// <summary>
    /// The single most important rule in the file: a credential must never be
    /// persisted to forge.json, and an attempt must be reported rather than
    /// silently written.
    /// </summary>
    [Theory]
    [InlineData("githubAppPrivateKey")]
    [InlineData("pacePassword")]
    [InlineData("azureClientSecret")]
    [InlineData("appleDevIdP12")]
    [InlineData("appleAscPrivateKey")]
    public void A_secret_key_anywhere_in_the_file_is_rejected(string secretKey)
    {
        JsonNode node = ValidNode();
        node[secretKey] = "some-value";

        IReadOnlyList<string> problems = ConfigStore.Validate(node);

        Assert.Contains(problems, p => p.Contains(secretKey, StringComparison.Ordinal)
                                       && p.Contains("SECRET", StringComparison.Ordinal));
    }

    [Fact]
    public void A_secret_nested_deep_in_the_file_is_still_rejected()
    {
        JsonNode node = ValidNode();
        node["signing"]!["macos"]!["pacePassword"] = "hunter2";

        IReadOnlyList<string> problems = ConfigStore.Validate(node);

        Assert.Contains(problems, p => p.Contains("/signing/macos/pacePassword", StringComparison.Ordinal));
    }

    [Fact]
    public void Replicas_outside_the_class_range_are_rejected()
    {
        JsonNode node = ValidNode();
        JsonArray runners = node["runners"]!.AsArray();

        foreach (JsonNode? runner in runners)
        {
            if (runner?["classId"]?.GetValue<string>() == "win-build") runner["replicas"] = 9;
        }

        Assert.Contains(ConfigStore.Validate(node), p => p.Contains("replicas", StringComparison.Ordinal));
    }

    /// <summary>An iLok class is fixed at one replica: there is one dongle.</summary>
    [Fact]
    public void An_ilok_class_may_not_have_more_than_one_replica()
    {
        JsonNode node = ValidNode();

        foreach (JsonNode? runner in node["runners"]!.AsArray())
        {
            if (runner?["classId"]?.GetValue<string>() == "win-ilok") runner["replicas"] = 2;
        }

        IReadOnlyList<string> problems = ConfigStore.Validate(node);

        Assert.Contains(problems, p => p.Contains("replicas", StringComparison.Ordinal)
                                       && p.Contains("dongle", StringComparison.Ordinal));
    }

    [Fact]
    public void An_unknown_class_id_is_rejected()
    {
        JsonNode node = ValidNode();
        node["runners"]!.AsArray()[0]!["classId"] = "win-magic";

        Assert.Contains(ConfigStore.Validate(node), p => p.Contains("classId", StringComparison.Ordinal));
    }

    /// <summary>
    /// Base images are never purged. Allowing false here would let a config
    /// instruct the Sweeper to destroy the thing that takes an hour to rebuild.
    /// </summary>
    [Fact]
    public void Keeping_base_images_cannot_be_turned_off()
    {
        JsonNode node = ValidNode();
        node["retention"]!["keepBaseImages"] = false;

        Assert.Contains(ConfigStore.Validate(node),
            p => p.Contains("keepBaseImages", StringComparison.Ordinal));
    }

    [Fact]
    public void Telemetry_cannot_be_turned_on()
    {
        JsonNode node = ValidNode();
        node["telemetry"] = true;

        Assert.Contains(ConfigStore.Validate(node), p => p.Contains("/telemetry", StringComparison.Ordinal));
    }

    // -----------------------------------------------------------------------
    // Unconfigured is not invalid.
    //
    // These four fields are what the GUI exists to collect. Treating them as
    // validation errors meant the app wrote a default forge.json on first run
    // and then refused to load the file it had just written on the second,
    // leaving no way in at all: the only way to fill them is the window that
    // would not open. See TROUBLESHOOTING #22.
    // -----------------------------------------------------------------------

    [Fact]
    public void A_freshly_created_default_config_loads_without_error()
    {
        ForgeConfig fresh = ForgeConfig.CreateDefault(@"C:\ProgramData\RunnerForge\work");
        string json = JsonSerializer.Serialize(fresh, ForgeConfig.SerializerOptions);

        Assert.Empty(ConfigStore.Validate(Parse(json)));

        // And the round trip the app actually performs: write defaults, read
        // them back. This is the exact sequence that was broken.
        ForgeConfig reloaded = new ConfigStore(new LogBus()).Parse(json);
        Assert.NotNull(reloaded);
    }

    [Fact]
    public void An_empty_repository_list_is_a_setup_gap_not_a_validation_error()
    {
        JsonNode node = ValidNode();
        node["github"]!["repos"] = new JsonArray();

        Assert.DoesNotContain(ConfigStore.Validate(node), p => p.Contains("/github/repos", StringComparison.Ordinal));

        ForgeConfig config = ValidConfig();
        config.GitHub.Repos = [];
        Assert.Contains(ConfigStore.DescribeSetupGaps(config), g => g.What.Contains("repository", StringComparison.Ordinal));
    }

    [Fact]
    public void Every_unconfigured_github_field_is_reported_as_a_gap_with_a_page_that_fixes_it()
    {
        ForgeConfig config = ForgeConfig.CreateDefault(@"C:\ProgramData\RunnerForge\work");

        IReadOnlyList<ConfigStore.SetupGap> gaps = ConfigStore.DescribeSetupGaps(config);

        Assert.Contains(gaps, g => g.What.Contains("owner", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(gaps, g => g.What.Contains("App ID", StringComparison.Ordinal));
        Assert.Contains(gaps, g => g.What.Contains("Installation ID", StringComparison.Ordinal));
        Assert.Contains(gaps, g => g.What.Contains("repository", StringComparison.OrdinalIgnoreCase));

        // A gap the user cannot act on is worse than no gap: every one must name
        // a real navigation page and say where the value comes from.
        string[] pages = ["Preflight", "Credentials", "Targets", "Runners", "Signing", "Export", "Logs", "Cleanup"];
        Assert.All(gaps, g =>
        {
            Assert.Contains(g.Page, pages);
            Assert.False(string.IsNullOrWhiteSpace(g.HowToFix));
        });
    }

    [Fact]
    public void A_fully_configured_config_reports_no_gaps()
    {
        Assert.Empty(ConfigStore.DescribeSetupGaps(ValidConfig()));
    }

    [Fact]
    public void A_structurally_broken_file_is_still_rejected()
    {
        // The distinction has to hold in both directions: things a text box
        // cannot fix must still block.
        JsonNode node = ValidNode();
        node["schemaVersion"] = 99;
        Assert.NotEmpty(ConfigStore.Validate(node));

        node = ValidNode();
        node["github"] = null;
        Assert.Contains(ConfigStore.Validate(node), p => p.StartsWith("/github", StringComparison.Ordinal));
    }

    [Fact]
    public void An_unknown_signing_mode_is_rejected()
    {
        JsonNode node = ValidNode();
        node["signing"]!["mode"] = "dongle-maybe";

        Assert.Contains(ConfigStore.Validate(node), p => p.Contains("/signing/mode", StringComparison.Ordinal));
    }

    [Fact]
    public void Malformed_json_reports_the_pointer_rather_than_throwing_a_raw_exception()
    {
        var store = new ConfigStore(new LogBus());

        ConfigValidationException exception =
            Assert.Throws<ConfigValidationException>(() => store.Parse("{ not json"));

        Assert.Contains(exception.Problems, p => p.Contains("not valid JSON", StringComparison.Ordinal));
    }

    [Fact]
    public void A_valid_document_round_trips_through_parse()
    {
        var store = new ConfigStore(new LogBus());
        ForgeConfig parsed = store.Parse(JsonSerializer.Serialize(ValidConfig(), ForgeConfig.SerializerOptions));

        Assert.Equal("AA-EION", parsed.GitHub.Owner);
        Assert.Equal(5, parsed.Runners.Count);
        Assert.Equal("windows-ilok", parsed.Signing.Mode);
        Assert.False(parsed.Telemetry);
    }

    /// <summary>The default signing mode is windows-ilok: that PC runs 24/7.</summary>
    [Fact]
    public void The_default_signing_mode_is_windows_ilok()
    {
        Assert.Equal(SigningMode.WindowsIlok,
            ForgeConfig.CreateDefault("/tmp/work").Signing.ModeEnum);
    }

    [Fact]
    public void Default_replica_counts_match_the_class_catalogue()
    {
        ForgeConfig config = ForgeConfig.CreateDefault("/tmp/work");

        Assert.Equal(2, config.Runners.First(r => r.ClassId == "win-build").Replicas);
        Assert.Equal(1, config.Runners.First(r => r.ClassId == "linux-util").Replicas);
        Assert.Equal(1, config.Runners.First(r => r.ClassId == "mac-build").Replicas);
        Assert.Equal(1, config.Runners.First(r => r.ClassId == "win-ilok").Replicas);
    }
}
