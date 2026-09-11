using System.Text.RegularExpressions;
using RunnerForge.Models;

namespace RunnerForge.Services;

/// <summary>
/// Substitutes <c>{{key}}</c> placeholders in the workflow templates.
/// </summary>
/// <remarks>
/// Hand-rolled on purpose: a template engine would be a dependency, a security
/// surface and a source of surprising behaviour for something that is literally
/// string replacement. The one rule that matters is that an UNSUBSTITUTED
/// placeholder is an error, not something to paste into a workflow and discover
/// later.
/// </remarks>
public sealed partial class TemplateRenderer
{
    [GeneratedRegex(@"\{\{([A-Za-z][A-Za-z0-9]*)\}\}", RegexOptions.Compiled)]
    private static partial Regex PlaceholderPattern();

    /// <summary>Raised when a template still contains placeholders after rendering.</summary>
    public sealed class UnsubstitutedPlaceholderException(IReadOnlyList<string> keys)
        : Exception($"The template still contains unsubstituted placeholders: {string.Join(", ", keys)}. "
                    + "Rendering an incomplete workflow would produce YAML that fails at run time.")
    {
        public IReadOnlyList<string> Keys { get; } = keys;
    }

    public string Render(string template, IReadOnlyDictionary<string, string> values)
    {
        ArgumentNullException.ThrowIfNull(template);
        ArgumentNullException.ThrowIfNull(values);

        string result = PlaceholderPattern().Replace(template, match =>
        {
            string key = match.Groups[1].Value;
            return values.TryGetValue(key, out string? value) ? value : match.Value;
        });

        List<string> remaining = [.. PlaceholderPattern().Matches(result)
            .Select(m => m.Groups[1].Value).Distinct().Order()];

        if (remaining.Count > 0) throw new UnsubstitutedPlaceholderException(remaining);

        return result;
    }

    /// <summary>Every placeholder a template uses, so the UI can show what a render needs.</summary>
    public IReadOnlyList<string> PlaceholdersIn(string template) =>
        [.. PlaceholderPattern().Matches(template).Select(m => m.Groups[1].Value).Distinct().Order()];

    /// <summary>
    /// The substitution map for a configuration. This is the single definition of
    /// how config becomes workflow, shared by the Export page and the self-test.
    /// </summary>

    /// <summary>
    /// The wraptool publisher arguments for this configuration, as a ready-made
    /// fragment. <c>--wcguid</c> when a Wrap Config is set, otherwise the
    /// customer number and company name, which wraptool requires together.
    /// </summary>
    public static string PaceIdentityArgs(ForgeConfig config, bool shell)
    {
        string guid = config.Signing.PaceWcGuid.Trim();
        if (guid.Length > 0)
        {
            return shell ? $"--wcguid '{guid}'" : $"-WcGuid '{guid}'";
        }

        string number = config.Signing.PaceCustomerNumber.Trim();
        string name = config.Signing.PaceCustomerName.Trim();
        if (number.Length == 0 || name.Length == 0)
        {
            // Deliberately not a silent empty string: an emitted workflow with no
            // publisher argument fails inside wraptool minutes later, with a
            // message that does not mention the configuration at all.
            const string marker = "SET-A-WRAP-CONFIG-OR-CUSTOMER-NUMBER-ON-THE-SIGNING-PAGE";
            return shell ? $"--wcguid '{marker}'" : $"-WcGuid '{marker}'";
        }

        return shell
            ? $"--customernumber '{number}' \\\n            --customername '{name}'"
            : $"-CustomerNumber '{number}' `\n            -CustomerName '{name}'";
    }

    public static Dictionary<string, string> BuildValues(
        ForgeConfig config,
        string projectName,
        string sourceDir,
        IReadOnlyDictionary<string, bool> secretPresence)
    {
        string LabelsJson(RunnerClassId id)
        {
            RunnerClass runnerClass = RunnerClass.All.First(c => c.Id == id);
            RunnerConfig? configured = config.Runners.FirstOrDefault(r => r.ClassId == runnerClass.ClassId);
            IReadOnlyList<string> labels = configured?.Labels is { Count: > 0 }
                ? configured.Labels
                : runnerClass.Labels;
            return "[" + string.Join(",", labels.Select(l => "\"" + l + "\"")) + "]";
        }

        string Present(string key) => secretPresence.TryGetValue(key, out bool has) && has ? "yes" : "no";

        bool aaxAvailable = !string.IsNullOrWhiteSpace(config.Paths.AaxSdkSource);

        return new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["projectName"] = projectName,
            ["sourceDir"] = sourceDir,
            ["githubOwner"] = config.GitHub.Owner,
            ["githubRepo"] = config.GitHub.Repos.FirstOrDefault() ?? "",
            ["pushBranches"] = "main",

            ["checkoutAction"] = "v4",
            ["uploadArtifactAction"] = "v4",
            ["downloadArtifactAction"] = "v4",

            ["winBuildLabelsJson"] = LabelsJson(RunnerClassId.WinBuild),
            ["macBuildLabelsJson"] = LabelsJson(RunnerClassId.MacBuild),
            ["linuxUtilLabelsJson"] = LabelsJson(RunnerClassId.LinuxUtil),
            ["winIlokLabelsJson"] = LabelsJson(RunnerClassId.WinIlok),
            ["macIlokLabelsJson"] = LabelsJson(RunnerClassId.MacIlok),

            ["winHostedJson"] = "\"windows-2022\"",
            ["macHostedJson"] = "\"macos-14\"",
            ["linuxHostedJson"] = "\"ubuntu-24.04\"",

            ["windowsTimeoutMinutes"] = "90",
            ["macosTimeoutMinutes"] = "90",

            ["fetchContentBaseDir"] = @"C:\cache\fetchcontent",
            ["sccacheDir"] = @"C:\cache\sccache",
            ["macFetchContentBaseDir"] = "$HOME/cache/fetchcontent",
            ["innoSetupScript"] = @"installer\windows\" + projectName + ".iss",
            ["macPackagingScript"] = "installer/macos/build_installer.sh",

            ["signingMode"] = config.Signing.Mode,
            ["signWorkflowFileName"] = "workflow-sign.yml",
            ["paceWcGuid"] = config.Signing.PaceWcGuid,
            ["paceSignId"] = config.Signing.PaceSignId,

            // These four expand to complete argument fragments rather than bare
            // values, because the shape of the call changes with the
            // configuration: a Wrap Config is one flag, a customer number is two,
            // and a self-signed certificate adds one more. Emitting the fragment
            // keeps that decision here instead of spreading conditionals through
            // YAML, where they cannot be unit-tested.
            ["paceIdentityArgsSh"] = PaceIdentityArgs(config, shell: true),
            ["paceIdentityArgsPs"] = PaceIdentityArgs(config, shell: false),
            ["paceSelfSignedSh"] = config.Signing.PaceSelfSigned ? " \\\n            --self-signed" : "",
            ["paceSelfSignedPs"] = config.Signing.PaceSelfSigned ? " `\n            -SelfSigned" : "",

            ["windowsSigningEnabled"] =
                config.Signing.Windows.Provider == "none" ? "false" : "true",
            ["azureEndpoint"] = config.Signing.Windows.AzureEndpoint,
            ["azureAccount"] = config.Signing.Windows.AzureAccount,
            ["azureProfile"] = config.Signing.Windows.AzureProfile,

            ["macosSigningEnabled"] = config.Signing.Macos.Notarize ? "true" : "false",
            ["devIdAppIdentity"] = config.Signing.Macos.DevIdAppIdentity,
            ["devIdInstallerIdentity"] = config.Signing.Macos.DevIdInstallerIdentity,
            ["appleTeamId"] = config.Signing.Macos.TeamId,

            // When there is no SDK the AAX artifacts become optional and the
            // skip marker becomes required, so the set is never silently short.
            ["aaxRequired"] = aaxAvailable ? "true" : "false",
            ["aaxSkipRequired"] = aaxAvailable ? "false" : "true",

            ["havePaceAccount"] = Present("paceAccount"),
            ["havePacePassword"] = Present("pacePassword"),
            ["haveAzureClientId"] = Present("azureClientId"),
            ["haveAzureClientSecret"] = Present("azureClientSecret"),
            ["haveAzureTenantId"] = Present("azureTenantId"),
            ["haveAppleP12"] = Present("appleDevIdP12"),
            ["haveAppleP12Password"] = Present("appleDevIdP12Password"),
            ["haveAscIssuerId"] = Present("appleAscIssuerId"),
            ["haveAscKeyId"] = Present("appleAscKeyId"),
            ["haveAscPrivateKey"] = Present("appleAscPrivateKey"),

            ["workflowName"] = projectName + "-selftest",
            ["workflowFileName"] = "selftest-selfhosted.yml",
            ["stageName"] = "Runner Forge self-test",
            ["winBuildLabels"] = "[" + string.Join(", ",
                RunnerClass.WinBuild.Labels) + "]",
            ["macBuildLabels"] = "[" + string.Join(", ",
                RunnerClass.MacBuild.Labels) + "]",
            ["linuxUtilLabels"] = "[" + string.Join(", ",
                RunnerClass.LinuxUtil.Labels) + "]",
        };
    }
}
