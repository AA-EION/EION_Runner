using RunnerForge.Models;
using RunnerForge.Services;
using Xunit;

namespace RunnerForge.Tests;

/// <summary>
/// The renderer is what turns configuration into the YAML a user pastes into
/// their repository, so its failure mode matters: an unsubstituted placeholder
/// must be an ERROR, never something quietly emitted.
/// </summary>
public sealed class TemplateRendererTests
{
    private readonly TemplateRenderer _renderer = new();

    [Fact]
    public void Substitutes_every_known_placeholder()
    {
        string result = _renderer.Render(
            "runs-on: {{labels}}\nname: {{project}}",
            new Dictionary<string, string> { ["labels"] = "[a,b]", ["project"] = "Canary" });

        Assert.Equal("runs-on: [a,b]\nname: Canary", result);
    }

    [Fact]
    public void Substitutes_a_repeated_placeholder_everywhere()
    {
        string result = _renderer.Render(
            "{{p}}-windows-x64 {{p}}-macos-universal {{p}}-logs",
            new Dictionary<string, string> { ["p"] = "Canary" });

        Assert.Equal("Canary-windows-x64 Canary-macos-universal Canary-logs", result);
    }

    /// <summary>
    /// Emitting YAML that still contains {{something}} would produce a workflow
    /// that fails at run time on the user's machine. Far better to refuse.
    /// </summary>
    [Fact]
    public void An_unsubstituted_placeholder_throws_rather_than_being_emitted()
    {
        TemplateRenderer.UnsubstitutedPlaceholderException exception =
            Assert.Throws<TemplateRenderer.UnsubstitutedPlaceholderException>(
                () => _renderer.Render("a: {{known}} b: {{missing}}",
                    new Dictionary<string, string> { ["known"] = "1" }));

        Assert.Contains("missing", exception.Keys);
        Assert.DoesNotContain("known", exception.Keys);
    }

    [Fact]
    public void Reports_every_missing_placeholder_not_just_the_first()
    {
        TemplateRenderer.UnsubstitutedPlaceholderException exception =
            Assert.Throws<TemplateRenderer.UnsubstitutedPlaceholderException>(
                () => _renderer.Render("{{a}} {{b}} {{c}}", new Dictionary<string, string>()));

        Assert.Equal(["a", "b", "c"], exception.Keys);
    }

    [Fact]
    public void Text_that_merely_looks_like_a_placeholder_is_left_alone()
    {
        // Shell parameter expansion and GitHub expressions both use braces, and
        // neither may be mangled.
        const string template = "run: echo ${HOME} and ${{ github.sha }}";
        string result = _renderer.Render(template, new Dictionary<string, string>());
        Assert.Equal(template, result);
    }

    [Fact]
    public void Lists_the_placeholders_a_template_uses()
    {
        IReadOnlyList<string> found = _renderer.PlaceholdersIn("{{b}} {{a}} {{b}}");
        Assert.Equal(["a", "b"], found);
    }

    [Fact]
    public void Built_values_render_label_sets_as_json_arrays()
    {
        ForgeConfig config = ForgeConfig.CreateDefault("/tmp/work");
        Dictionary<string, string> values =
            TemplateRenderer.BuildValues(config, "Canary", ".", new Dictionary<string, bool>());

        Assert.Equal("""["self-hosted","windows","x64","container","forge"]""", values["winBuildLabelsJson"]);
        Assert.Equal("""["self-hosted","macos","arm64","tart","forge"]""", values["macBuildLabelsJson"]);
        Assert.Equal("""["self-hosted","windows","x64","ilok","forge"]""", values["winIlokLabelsJson"]);
    }

    /// <summary>
    /// With no AAX SDK the AAX artifacts become optional and the skip marker
    /// becomes required, so the artifact set is never silently short.
    /// </summary>
    [Fact]
    public void Without_an_aax_sdk_the_skip_marker_becomes_required()
    {
        ForgeConfig config = ForgeConfig.CreateDefault("/tmp/work");
        config.Paths.AaxSdkSource = "";

        Dictionary<string, string> values =
            TemplateRenderer.BuildValues(config, "Canary", ".", new Dictionary<string, bool>());

        Assert.Equal("false", values["aaxRequired"]);
        Assert.Equal("true", values["aaxSkipRequired"]);
    }

    [Fact]
    public void With_an_aax_sdk_the_aax_artifacts_become_required()
    {
        ForgeConfig config = ForgeConfig.CreateDefault("/tmp/work");
        config.Paths.AaxSdkSource = @"C:\sdk\aax.zip";

        Dictionary<string, string> values =
            TemplateRenderer.BuildValues(config, "Canary", ".", new Dictionary<string, bool>());

        Assert.Equal("true", values["aaxRequired"]);
        Assert.Equal("false", values["aaxSkipRequired"]);
    }

    [Fact]
    public void Secret_presence_is_reported_as_yes_or_no_and_never_as_a_value()
    {
        ForgeConfig config = ForgeConfig.CreateDefault("/tmp/work");

        Dictionary<string, string> values = TemplateRenderer.BuildValues(
            config, "Canary", ".",
            new Dictionary<string, bool> { ["pacePassword"] = true, ["azureClientId"] = false });

        Assert.Equal("yes", values["havePacePassword"]);
        Assert.Equal("no", values["haveAzureClientId"]);
    }

    /// <summary>
    /// Setting the provider to none must disable the signing step rather than
    /// emitting a step that will fail for want of credentials.
    /// </summary>
    [Fact]
    public void Windows_signing_is_disabled_when_the_provider_is_none()
    {
        ForgeConfig config = ForgeConfig.CreateDefault("/tmp/work");
        config.Signing.Windows.Provider = "none";

        Dictionary<string, string> values =
            TemplateRenderer.BuildValues(config, "Canary", ".", new Dictionary<string, bool>());

        Assert.Equal("false", values["windowsSigningEnabled"]);
    }
}
