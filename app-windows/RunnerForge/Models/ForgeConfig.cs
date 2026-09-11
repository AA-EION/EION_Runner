using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace RunnerForge.Models;

/// <summary>
/// The contract between the GUI and every script: forge.json.
/// </summary>
/// <remarks>
/// NO SECRET MAY EVER APPEAR IN THIS TYPE. It carries only non-secret
/// identifiers — app ids, installation ids, certificate common names, Azure
/// endpoint names. Every actual credential lives in the OS keystore. A property
/// here that holds a password is a bug, not a feature.
/// </remarks>
public sealed class ForgeConfig
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; set; } = 1;

    [JsonPropertyName("github")]
    public GitHubConfig GitHub { get; set; } = new();

    [JsonPropertyName("runners")]
    public List<RunnerConfig> Runners { get; set; } = [];

    [JsonPropertyName("signing")]
    public SigningConfig Signing { get; set; } = new();

    [JsonPropertyName("paths")]
    public PathsConfig Paths { get; set; } = new();

    [JsonPropertyName("retention")]
    public RetentionConfig Retention { get; set; } = new();

    [JsonPropertyName("limits")]
    public LimitsConfig Limits { get; set; } = new();

    [JsonPropertyName("verification")]
    public VerificationConfig Verification { get; set; } = new();

    /// <summary>
    /// Runner Forge sends no telemetry. The property exists so the absence is
    /// explicit and auditable rather than merely unmentioned.
    /// </summary>
    [JsonPropertyName("telemetry")]
    public bool Telemetry { get; set; }

    public static JsonSerializerOptions SerializerOptions { get; } = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    /// <summary>A config with every default filled in, for a first run.</summary>
    public static ForgeConfig CreateDefault(string workDir) => new()
    {
        SchemaVersion = 1,
        Runners = RunnerClass.All.Select(RunnerConfig.FromClass).ToList(),
        Paths = new PathsConfig { WorkDir = workDir, AaxSdkSource = "" },
        Telemetry = false,
    };
}

public sealed class GitHubConfig
{
    [JsonPropertyName("owner")] public string Owner { get; set; } = "";
    [JsonPropertyName("repos")] public List<string> Repos { get; set; } = [];

    /// <summary>GitHub App id. NOT a secret; the private key lives in the keystore.</summary>
    [JsonPropertyName("appId")] public string AppId { get; set; } = "";

    /// <summary>Installation id of the App on the owner account. NOT a secret.</summary>
    [JsonPropertyName("installationId")] public string InstallationId { get; set; } = "";
}

public sealed class RunnerConfig
{
    [JsonPropertyName("classId")] public string ClassId { get; set; } = "";
    [JsonPropertyName("enabled")] public bool Enabled { get; set; }
    [JsonPropertyName("replicas")] public int Replicas { get; set; } = 1;
    [JsonPropertyName("labels")] public List<string> Labels { get; set; } = [];
    [JsonPropertyName("jobTimeoutMinutes")] public int JobTimeoutMinutes { get; set; } = 60;

    public static RunnerConfig FromClass(RunnerClass runnerClass) => new()
    {
        ClassId = runnerClass.ClassId,
        Enabled = false,
        Replicas = runnerClass.DefaultReplicas,
        Labels = [.. runnerClass.Labels],
        JobTimeoutMinutes = 60,
    };
}

public sealed class SigningConfig
{
    /// <summary>Default is windows-ilok: the user's Windows PC runs 24/7.</summary>
    [JsonPropertyName("mode")] public string Mode { get; set; } = "windows-ilok";

    [JsonPropertyName("paceAccount")] public string PaceAccount { get; set; } = "";
    [JsonPropertyName("paceWcGuid")] public string PaceWcGuid { get; set; } = "";
    [JsonPropertyName("paceSignId")] public string PaceSignId { get; set; } = "";

    /// <summary>Append --allowsigningservice to wraptool in cloud mode.</summary>
    [JsonPropertyName("allowSigningService")] public bool AllowSigningService { get; set; } = true;

    [JsonPropertyName("windows")] public WindowsSigningConfig Windows { get; set; } = new();
    [JsonPropertyName("macos")] public MacosSigningConfig Macos { get; set; } = new();

    [JsonIgnore]
    public SigningMode ModeEnum
    {
        get => SigningModeExtensions.FromConfigValue(Mode);
        set => Mode = value.ToConfigValue();
    }
}

public sealed class WindowsSigningConfig
{
    [JsonPropertyName("provider")] public string Provider { get; set; } = "azure-trusted-signing";
    [JsonPropertyName("azureEndpoint")] public string AzureEndpoint { get; set; } = "";
    [JsonPropertyName("azureAccount")] public string AzureAccount { get; set; } = "";
    [JsonPropertyName("azureProfile")] public string AzureProfile { get; set; } = "";
}

public sealed class MacosSigningConfig
{
    [JsonPropertyName("teamId")] public string TeamId { get; set; } = "";

    /// <summary>A certificate common name, not a key. Safe to store here.</summary>
    [JsonPropertyName("devIdAppIdentity")] public string DevIdAppIdentity { get; set; } = "";

    [JsonPropertyName("devIdInstallerIdentity")] public string DevIdInstallerIdentity { get; set; } = "";
    [JsonPropertyName("notarize")] public bool Notarize { get; set; } = true;
}

public sealed class PathsConfig
{
    [JsonPropertyName("workDir")] public string WorkDir { get; set; } = "";

    /// <summary>
    /// Local zip path or private git URL for the Avid AAX SDK. NEVER baked into
    /// an image layer; mounted from a local named volume at build time. Empty
    /// means AAX targets are skipped and the workflow emits a marker artifact
    /// naming the reason.
    /// </summary>
    [JsonPropertyName("aaxSdkSource")] public string AaxSdkSource { get; set; } = "";
}

public sealed class RetentionConfig
{
    /// <summary>Always true. Rebuilding base images costs tens of minutes.</summary>
    [JsonPropertyName("keepBaseImages")] public bool KeepBaseImages { get; set; } = true;

    /// <summary>Always true. Only per-job VM clones are ever deleted.</summary>
    [JsonPropertyName("keepTartImages")] public bool KeepTartImages { get; set; } = true;

    [JsonPropertyName("keepCaches")] public bool KeepCaches { get; set; } = true;
    [JsonPropertyName("purgeOnExit")] public bool PurgeOnExit { get; set; } = true;
    [JsonPropertyName("logRetentionDays")] public int LogRetentionDays { get; set; } = 7;
}

public sealed class LimitsConfig
{
    [JsonPropertyName("maxDiskGb")] public int MaxDiskGb { get; set; } = 120;
}

public sealed class VerificationConfig
{
    [JsonPropertyName("canaryRepo")] public string CanaryRepo { get; set; } = "";

    /// <summary>Consecutive green runs required before the setup counts as stable.</summary>
    [JsonPropertyName("requiredGreenRuns")] public int RequiredGreenRuns { get; set; } = 3;

    /// <summary>Written by SelfTestService. Null until the first self-test.</summary>
    [JsonPropertyName("lastProof")] public SelfTestResult? LastProof { get; set; }
}
