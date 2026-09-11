using System.Security.Cryptography.X509Certificates;
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

    // -----------------------------------------------------------------------
    // Finding wraptool
    //
    // The Fusion SDK installs wraptool at a VERSIONED path that is not on PATH,
    // so checking PATH alone answers "no" on a machine where it is installed and
    // working. That is how a correctly configured PC ends up staring at a red
    // requirement row it cannot clear.
    // -----------------------------------------------------------------------

    /// <summary>The path to wraptool.exe, or null. A WRAPTOOL environment
    /// variable wins, so an unusual install can be pointed at without edits.</summary>
    public static string? FindWraptool()
    {
        string? overridePath = Environment.GetEnvironmentVariable("WRAPTOOL");
        if (!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath)) return overridePath;

        string? onPath = ResolveOnPath("wraptool.exe");
        if (onPath is not null) return onPath;

        foreach (string root in SdkVersionRoots())
        {
            if (!Directory.Exists(root)) continue;

            // Newest major version first: "10" must sort above "6".
            var versions = Directory.GetDirectories(root)
                .OrderByDescending(d => int.TryParse(Path.GetFileName(d), out int n) ? n : -1);

            foreach (string version in versions)
            {
                string candidate = Path.Combine(version, "bin", "wraptool.exe");
                if (File.Exists(candidate)) return candidate;
            }
        }
        return null;
    }

    /// <summary>
    /// iloktool.exe opens iLok Cloud sessions. It ships with iLok License
    /// Manager, NOT with the Fusion SDK, which is why it is looked up separately
    /// and at a different path.
    /// </summary>
    public static string? FindIloktool()
    {
        string? overridePath = Environment.GetEnvironmentVariable("ILOKTOOL");
        if (!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath)) return overridePath;

        string? onPath = ResolveOnPath("iloktool.exe");
        if (onPath is not null) return onPath;

        // iLok License Manager installs 32-bit by default, so ProgramFiles(x86)
        // is the normal location even on 64-bit Windows.
        string[] candidates =
        [
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                         "iLok License Manager", "iloktool.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                         "iLok License Manager", "iloktool.exe"),
        ];
        return candidates.FirstOrDefault(File.Exists);
    }

    private static IEnumerable<string> SdkVersionRoots()
    {
        yield return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "PACEAntiPiracy", "Eden", "Fusion", "Versions");
        yield return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            "PACEAntiPiracy", "Eden", "Fusion", "Versions");
    }

    private static string? ResolveOnPath(string executable)
    {
        string search = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string directory in search.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(directory.Trim(), executable);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>One row in the signing-certificate picker.</summary>
    /// <param name="Thumbprint">
    /// The 40-character SHA-1 thumbprint. On Windows this is what wraptool takes
    /// as --signid — NOT the subject name, which is what macOS wants. Getting
    /// those two the wrong way round is the most common mistake here, which is
    /// why the UI offers a list rather than a text field.
    /// </param>
    public sealed record SigningCertificate(string Thumbprint, string Subject, bool SelfSigned, DateTime NotAfter)
    {
        public bool Expired => NotAfter < DateTime.Now;
        public string Display => $"{Subject}  ({Thumbprint[..8]}…)";
    }

    /// <summary>Every code-signing certificate this user can sign with.</summary>
    public IReadOnlyList<SigningCertificate> ListSigningCertificates()
    {
        if (!OperatingSystem.IsWindows()) return [];

        var found = new List<SigningCertificate>();
        foreach (var location in new[] { StoreLocation.CurrentUser, StoreLocation.LocalMachine })
        {
            try
            {
                using var store = new X509Store(StoreName.My, location);
                store.Open(OpenFlags.ReadOnly);

                foreach (X509Certificate2 certificate in store.Certificates)
                {
                    if (!HasCodeSigningEku(certificate)) continue;

                    found.Add(new SigningCertificate(
                        certificate.Thumbprint,
                        certificate.Subject,
                        // Self-signed is exactly "the issuer is the subject".
                        SelfSigned: certificate.Subject == certificate.Issuer,
                        certificate.NotAfter));
                }
            }
            catch (Exception error)
            {
                _logBus.Warning("signing", $"could not read the {location} certificate store: {error.Message}");
            }
        }

        return found
            .GroupBy(c => c.Thumbprint)
            .Select(g => g.First())
            .OrderBy(c => c.Expired)
            .ThenBy(c => c.Subject)
            .ToList();
    }

    private static bool HasCodeSigningEku(X509Certificate2 certificate)
    {
        foreach (X509Extension extension in certificate.Extensions)
        {
            if (extension is not X509EnhancedKeyUsageExtension eku) continue;
            foreach (System.Security.Cryptography.Oid oid in eku.EnhancedKeyUsages)
            {
                // 1.3.6.1.5.5.7.3.3 is id-kp-codeSigning.
                if (oid.Value == "1.3.6.1.5.5.7.3.3") return true;
            }
        }
        return false;
    }

    /// <summary>
    /// Creates a self-signed code-signing certificate by running the shipped
    /// generator, which uses the New-SelfSignedCertificate invocation PACE
    /// publishes.
    /// </summary>
    /// <remarks>
    /// The private key lands in the Windows certificate store. It is never
    /// written beside the plugin and never shipped inside the bundle: a signing
    /// key that travels with the artifact is a published key.
    /// </remarks>
    public async Task<bool> GenerateSelfSignedCertificateAsync(
        string subject, string scriptsDirectory, CancellationToken cancellationToken = default)
    {
        string script = Path.Combine(scriptsDirectory, "make-signing-cert.ps1");
        if (!File.Exists(script))
        {
            _logBus.Error("signing", $"certificate generator not found: {script}");
            return false;
        }

        _logBus.Warning("signing",
            "Creating a SELF-SIGNED certificate. PACE recommends these only while learning the "
            + "signing tools. A plugin signed with one still loads in Pro Tools — the PACE signature "
            + "is what Pro Tools checks — but Windows will not trust the Authenticode signature on "
            + "any machine that has not been told to. See docs/SIGNING.md.");

        ProcessResult result = await _processRunner.RunAsync(
            "powershell.exe",
            ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-Subject", subject],
            logSource: "signing", cancellationToken: cancellationToken).ConfigureAwait(false);

        return result.Succeeded;
    }

    /// <summary>Requirements for a mode, evaluated against this machine right now.</summary>
    public IReadOnlyList<SigningRequirement> RequirementsFor(SigningMode mode, ForgeConfig config)
    {
        bool hasAccount = !string.IsNullOrWhiteSpace(config.Signing.PaceAccount);
        bool hasPassword = _secretStore.Has("pacePassword");
        bool hasPublisher = config.Signing.HasPublisherIdentity;
        bool wraptool = FindWraptool() is not null;

        // On Windows --signid is a THUMBPRINT, so "set" is not enough: the
        // certificate has to actually be in a store this user can read, and not
        // expired.
        string configuredId = config.Signing.PaceSignId.Trim();
        IReadOnlyList<SigningCertificate> certificates = ListSigningCertificates();
        SigningCertificate? certificate =
            certificates.FirstOrDefault(c => string.Equals(c.Thumbprint, configuredId, StringComparison.OrdinalIgnoreCase));
        bool hasSignId = certificate is not null && !certificate.Expired;

        string signIdFix =
            configuredId.Length == 0
                ? certificates.Count == 0
                    ? "No code-signing certificate exists on this PC. Use Create self-signed certificate "
                      + "on the Signing page, or install an Authenticode certificate from a "
                      + "Microsoft-approved CA. If yours is on a hardware token, attach the token first."
                    : "Pick one from the list on the Signing page."
                : certificate is null
                    ? $"No certificate with thumbprint {configuredId} is in the Personal store. On Windows "
                      + "--signid takes the 40-character thumbprint, not the subject name."
                    : $"That certificate expired on {certificate.NotAfter:d}.";

        const string publisherFix =
            "Set a Wrap Config GUID, or a customer number AND company name — wraptool needs one or "
            + "the other, and rejects a customer number on its own.";

        string wraptoolFix =
            "Install the PACE Fusion SDK. Runner Forge looks on PATH and under "
            + @"%ProgramFiles%\PACEAntiPiracy\Eden\Fusion\Versions\*\bin\wraptool.exe, so it finds a "
            + "normal SDK install even though the SDK does not add itself to PATH.";

        return mode switch
        {
            SigningMode.Cloud =>
            [
                new("PACE account name is set", hasAccount, "Enter it on the Signing page."),
                new("PACE password is stored", hasPassword, "Enter it on the Credentials page."),
                new("Publisher identified (Wrap Config, or customer number + name)", hasPublisher, publisherFix),
                new("Signing certificate present and unexpired", hasSignId, signIdFix),
                new("wraptool found", wraptool, wraptoolFix),
                new("iloktool found (opens the iLok Cloud session)", FindIloktool() is not null,
                    "Install iLok License Manager from ilok.com — iloktool ships with it, not with the "
                    + "Fusion SDK. Or open the Cloud session by hand from iLok License Manager: "
                    + "File > Open Your Cloud Session."),
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
                new("wraptool found", wraptool, wraptoolFix),
                new("PACE password is stored", hasPassword,
                    "Enter it on the Credentials page (optional if iLok License Manager is signed in — "
                    + "wraptool finds the account itself)."),
                new("Publisher identified (Wrap Config, or customer number + name)", hasPublisher, publisherFix),
                new("Signing certificate present and unexpired", hasSignId, signIdFix),
                new(certificate?.SelfSigned == true || config.Signing.PaceSelfSigned
                        ? "Certificate is SELF-SIGNED — testing only"
                        : "Certificate chains to a trusted authority",
                    certificate is not null && !certificate.SelfSigned,
                    "This certificate is its own issuer, which is what a self-signed certificate is. The "
                    + "plugin will still load in Pro Tools — Pro Tools checks the PACE signature, not "
                    + "Authenticode — but Windows will not trust it anywhere it has not been installed as "
                    + "a trusted root. See docs/SIGNING.md before distributing it."),
                new("win-ilok runner enabled", IsClassEnabled(config, "win-ilok"),
                    "Enable it on the Runners page."),
            ],

            SigningMode.MacosIlok =>
            [
                new("The dongle is in the Mac, not this PC", true,
                    "macos-ilok signs on the Mac. This machine only needs the configuration."),
                new("PACE password is stored", hasPassword, "Enter it on the Credentials page."),
                new("Publisher identified (Wrap Config, or customer number + name)", hasPublisher, publisherFix),
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

        string? account = _secretStore.Read("paceAccount") ?? config.Signing.PaceAccount;
        string? password = _secretStore.Read("pacePassword");

        // Cloud signing REQUIRES both: PACE documents --allowsigningservice as
        // needing an account and a password. The iLok path does not — wraptool
        // finds the account itself when iLok License Manager is signed in — so
        // demanding them there would block a setup that already works.
        if (mode == SigningMode.Cloud
            && (string.IsNullOrWhiteSpace(account) || string.IsNullOrWhiteSpace(password)))
        {
            _logBus.Error("signing",
                "cannot cloud-sign: PACE_ACCOUNT and PACE_PASSWORD are both required, because "
                + "--allowsigningservice is documented as needing them. They live in Credential Manager "
                + "and are injected as environment variables; they never appear in forge.json.");
            return false;
        }

        if (!config.Signing.HasPublisherIdentity)
        {
            _logBus.Error("signing",
                "cannot sign: wraptool needs the publisher named, by a Wrap Config GUID or by a customer "
                + "number AND company name. It rejects a customer number on its own.");
            return false;
        }

        var environment = new Dictionary<string, string>();
        if (!string.IsNullOrWhiteSpace(account)) environment["PACE_ACCOUNT"] = account;
        if (!string.IsNullOrWhiteSpace(password)) environment["PACE_PASSWORD"] = password;

        var arguments = new List<string>
        {
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script,
            "-InputPath", bundlePath,
            "-SignId", config.Signing.PaceSignId,
        };

        // EITHER a Wrap Config GUID OR the customer number paired with the
        // company name. wraptool rejects the number without the name.
        if (!string.IsNullOrWhiteSpace(config.Signing.PaceWcGuid))
        {
            arguments.AddRange(["-WcGuid", config.Signing.PaceWcGuid]);
        }
        else
        {
            arguments.AddRange([
                "-CustomerNumber", config.Signing.PaceCustomerNumber,
                "-CustomerName", config.Signing.PaceCustomerName,
            ]);
        }

        // A self-signed certificate changes what the script promises, not what
        // it does to the PACE signature.
        if (config.Signing.PaceSelfSigned) arguments.Add("-SelfSigned");

        // Cloud signing needs an open iLok Cloud session. Opening one is the
        // only documented call that puts the password on a command line, so it
        // is requested explicitly rather than assumed.
        if (mode == SigningMode.Cloud) arguments.Add("-OpenSession");

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
