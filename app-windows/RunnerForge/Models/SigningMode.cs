namespace RunnerForge.Models;

/// <summary>The three AAX signing strategies.</summary>
public enum SigningMode
{
    /// <summary>PACE Cloud 2 Cloud. No dongle anywhere; signs inside the build job.</summary>
    Cloud,

    /// <summary>Physical dongle in the Windows PC. The default: that machine runs 24/7.</summary>
    WindowsIlok,

    /// <summary>Physical dongle in the Mac.</summary>
    MacosIlok,
}

/// <summary>Authenticode provider for Windows binaries. Independent of AAX signing.</summary>
public enum WindowsSigningProvider
{
    /// <summary>Do not Authenticode-sign. Artifacts are still produced, just unsigned.</summary>
    None,

    /// <summary>Azure Trusted Signing. A cloud HSM holds the key, so this runs inside the container.</summary>
    AzureTrustedSigning,
}

/// <summary>One item in a signing mode's live requirement checklist.</summary>
public sealed record SigningRequirement(string Description, bool Satisfied, string? HowToFix = null);

public static class SigningModeExtensions
{
    public static string ToConfigValue(this SigningMode mode) => mode switch
    {
        SigningMode.Cloud => "cloud",
        SigningMode.WindowsIlok => "windows-ilok",
        SigningMode.MacosIlok => "macos-ilok",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    public static SigningMode FromConfigValue(string value) => value switch
    {
        "cloud" => SigningMode.Cloud,
        "windows-ilok" => SigningMode.WindowsIlok,
        "macos-ilok" => SigningMode.MacosIlok,
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "Unknown signing mode."),
    };

    public static string ToDisplayName(this SigningMode mode) => mode switch
    {
        SigningMode.Cloud => "Cloud (PACE Cloud 2 Cloud)",
        SigningMode.WindowsIlok => "Windows iLok (this machine)",
        SigningMode.MacosIlok => "macOS iLok (the Mac)",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    public static string ToConfigValue(this WindowsSigningProvider provider) => provider switch
    {
        WindowsSigningProvider.None => "none",
        WindowsSigningProvider.AzureTrustedSigning => "azure-trusted-signing",
        _ => throw new ArgumentOutOfRangeException(nameof(provider)),
    };

    public static WindowsSigningProvider ProviderFromConfigValue(string value) => value switch
    {
        "none" => WindowsSigningProvider.None,
        "azure-trusted-signing" => WindowsSigningProvider.AzureTrustedSigning,
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "Unknown Windows signing provider."),
    };
}
