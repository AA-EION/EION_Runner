using RunnerForge.Models;

namespace RunnerForge.Services;

/// <summary>
/// The live requirement checklist behind the Signing page, and the entry points
/// that invoke the signing scripts.
/// </summary>
/// <remarks>
/// Selecting a mode whose requirements are unmet is ALLOWED — people configure
/// before they install — but it raises a persistent warning and disables Export,
/// because emitting a workflow that cannot sign is worse than refusing to emit
/// one.
/// </remarks>
public sealed class SigningService(LogBus logBus, ProcessRunner processRunner, SecretStore secretStore)
{
    private readonly LogBus _logBus = logBus;
    private readonly ProcessRunner _processRunner = processRunner;
    private readonly SecretStore _secretStore = secretStore;

    /// <summary>Requirements for a mode, evaluated against this machine right now.</summary>
    public IReadOnlyList<SigningRequirement> RequirementsFor(SigningMode mode, ForgeConfig config)
    {
        bool hasAccount = !string.IsNullOrWhiteSpace(config.Signing.PaceAccount);
        bool hasPassword = _secretStore.Has("pacePassword");
        bool hasWcGuid = !string.IsNullOrWhiteSpace(config.Signing.PaceWcGuid);
        bool hasSignId = !string.IsNullOrWhiteSpace(config.Signing.PaceSignId);
        bool wraptool = ProcessRunner.IsOnPath("wraptool");

        return mode switch
        {
            SigningMode.Cloud =>
            [
                new("PACE account name is set", hasAccount, "Enter it on the Signing page."),
                new("PACE password is stored", hasPassword, "Enter it on the Credentials page."),
                new("paceWcGuid is set", hasWcGuid, "Enter the wrapping certificate GUID."),
                new("paceSignId is set", hasSignId, "Enter the signing identifier."),
                new("PACE Eden tools are in the win-build image", wraptool,
                    "Rebuild the image with Eden tools in the declared toolchain."),
                new("The account is entitled to iLok Cloud (Cloud 2 Cloud)", false,
                    "CONFIRM THIS WITH PACE. --allowsigningservice is the documented flag, but the flag is "
                    + "only half the story: the ACCOUNT has to be entitled. Runner Forge cannot verify this "
                    + "for you, so it is listed unmet until you have checked."),
            ],

            SigningMode.WindowsIlok =>
            [
                new("iLok driver installed on this host", IlokDriverPresent(),
                    "Install iLok License Manager."),
                new("Dongle detected", false,
                    "Plug the dongle into this machine. Preflight reports the live state; a Windows "
                    + "container can never see it, which is why win-ilok is a host process."),
                new("wraptool.exe on PATH", wraptool, "Install PACE Eden tools."),
                new("PACE password is stored", hasPassword, "Enter it on the Credentials page."),
                new("paceWcGuid and paceSignId are set", hasWcGuid && hasSignId, "Enter both on the Signing page."),
                new("win-ilok runner enabled", IsClassEnabled(config, "win-ilok"),
                    "Enable it on the Runners page."),
            ],

            SigningMode.MacosIlok =>
            [
                new("The dongle is in the Mac, not this PC", true,
                    "macos-ilok signs on the Mac. This machine only needs the configuration."),
                new("PACE password is stored", hasPassword, "Enter it on the Credentials page."),
                new("paceWcGuid and paceSignId are set", hasWcGuid && hasSignId, "Enter both on the Signing page."),
                new("mac-ilok runner enabled", IsClassEnabled(config, "mac-ilok"),
                    "Enable it on the Runners page, and on the Mac."),
                new("win-ilok is disabled", !IsClassEnabled(config, "win-ilok"),
                    "The two iLok classes are mutually exclusive: the dongle is in one machine or the other."),
            ],

            _ => [],
        };
    }

    private static bool IsClassEnabled(ForgeConfig config, string classId) =>
        config.Runners.FirstOrDefault(r => r.ClassId == classId)?.Enabled ?? false;

    private static bool IlokDriverPresent() =>
        OperatingSystem.IsWindows()
        && Directory.Exists(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "PACE"));

    /// <summary>True when every requirement is met and Export may proceed.</summary>
    public bool IsSatisfied(SigningMode mode, ForgeConfig config) =>
        RequirementsFor(mode, config).All(r => r.Satisfied);

    /// <summary>
    /// Runs the AAX signing script for the configured mode.
    /// </summary>
    /// <remarks>
    /// Credentials go into the child's ENVIRONMENT, never its arguments: an
    /// argument list is readable from the process list by any user on the machine.
    /// </remarks>
    public async Task<bool> SignAaxAsync(
        ForgeConfig config, string scriptsDirectory, string bundlePath, bool dryRun,
        CancellationToken cancellationToken = default)
    {
        SigningMode mode = config.Signing.ModeEnum;

        string script = mode == SigningMode.Cloud
            ? Path.Combine(scriptsDirectory, "sign-aax-cloud.ps1")
            : Path.Combine(scriptsDirectory, "sign-aax-ilok.ps1");

        if (!File.Exists(script))
        {
            _logBus.Error("signing", $"signing script not found: {script}");
            return false;
        }

        var environment = new Dictionary<string, string>();

        string? account = _secretStore.Read("paceAccount") ?? config.Signing.PaceAccount;
        string? password = _secretStore.Read("pacePassword");

        if (string.IsNullOrWhiteSpace(account) || string.IsNullOrWhiteSpace(password))
        {
            _logBus.Error("signing",
                "cannot sign: PACE_ACCOUNT and PACE_PASSWORD are required. They live in Credential Manager "
                + "and are injected as environment variables; they never appear in forge.json.");
            return false;
        }

        environment["PACE_ACCOUNT"] = account;
        environment["PACE_PASSWORD"] = password;

        var arguments = new List<string>
        {
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script,
            "-InputPath", bundlePath,
            "-WcGuid", config.Signing.PaceWcGuid,
            "-SignId", config.Signing.PaceSignId,
        };

        if (dryRun) arguments.Add("-DryRun");

        ProcessResult result = await _processRunner.RunAsync(
            "powershell.exe", arguments, environment: environment,
            logSource: "signing", cancellationToken: cancellationToken).ConfigureAwait(false);

        return result.Succeeded;
    }

    /// <summary>Authenticode-signs Windows binaries via Azure Trusted Signing.</summary>
    public async Task<bool> SignWindowsArtifactsAsync(
        ForgeConfig config, string scriptsDirectory, string artifactDirectory, bool dryRun,
        CancellationToken cancellationToken = default)
    {
        if (config.Signing.Windows.Provider == "none")
        {
            _logBus.Info("signing", "Authenticode signing is disabled (provider = none). "
                                    + "Artifacts are still produced, just unsigned.");
            return true;
        }

        string script = Path.Combine(scriptsDirectory, "sign-windows-artifact.ps1");
        if (!File.Exists(script))
        {
            _logBus.Error("signing", $"signing script not found: {script}");
            return false;
        }

        var environment = new Dictionary<string, string>();
        foreach (string key in new[] { "azureClientId", "azureClientSecret", "azureTenantId" })
        {
            string? value = _secretStore.Read(key);
            if (string.IsNullOrWhiteSpace(value))
            {
                _logBus.Error("signing", $"cannot sign: '{key}' is not stored. Add it on the Credentials page.");
                return false;
            }

            string variable = key switch
            {
                "azureClientId" => "AZURE_CLIENT_ID",
                "azureClientSecret" => "AZURE_CLIENT_SECRET",
                _ => "AZURE_TENANT_ID",
            };
            environment[variable] = value;
        }

        var arguments = new List<string>
        {
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script,
            "-ArtifactDir", artifactDirectory,
            "-Endpoint", config.Signing.Windows.AzureEndpoint,
            "-Account", config.Signing.Windows.AzureAccount,
            "-Profile", config.Signing.Windows.AzureProfile,
        };

        if (dryRun) arguments.Add("-DryRun");

        ProcessResult result = await _processRunner.RunAsync(
            "powershell.exe", arguments, environment: environment,
            logSource: "signing", cancellationToken: cancellationToken).ConfigureAwait(false);

        return result.Succeeded;
    }
}
