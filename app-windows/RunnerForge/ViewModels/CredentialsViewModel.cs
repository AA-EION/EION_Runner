using System.Collections.ObjectModel;
using System.Runtime.Versioning;
using RunnerForge.Models;
using RunnerForge.Services;

namespace RunnerForge.ViewModels;

/// <summary>One secure field on the Credentials page.</summary>
public sealed class CredentialField(string keyName, string displayName, string description) : ObservableObject
{
    private bool _isStored;

    public string KeyName { get; } = keyName;
    public string DisplayName { get; } = displayName;
    public string Description { get; } = description;

    public bool IsStored
    {
        get => _isStored;
        set => SetProperty(ref _isStored, value);
    }

    /// <summary>Shown instead of a value. The value is never read back into the UI.</summary>
    public string StatusText => IsStored ? "stored" : "not set";
}

/// <summary>
/// Backs the Credentials page.
/// </summary>
/// <remarks>
/// Values flow one way: from a PasswordBox into the keystore. Nothing ever reads
/// a secret back out to display it, so a shoulder-surfer and a screenshot see
/// the same thing — "stored".
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class CredentialsViewModel : ObservableObject
{
    private readonly SecretStore _secretStore;
    private readonly GitHubAppService _appService;
    private readonly Func<ForgeConfig> _configAccessor;
    private readonly Action _saveConfig;

    private string _testResult = "";

    public CredentialsViewModel(
        SecretStore secretStore, GitHubAppService appService, Func<ForgeConfig> configAccessor,
        Action saveConfig)
    {
        _secretStore = secretStore;
        _appService = appService;
        _configAccessor = configAccessor;
        _saveConfig = saveConfig;

        Fields =
        [
            new("githubAppPrivateKey", "GitHub App private key",
                "The .pem you downloaded when creating the App. Required to mint JIT configs."),
            new("paceAccount", "PACE account", "Your PACE/iLok account name."),
            new("pacePassword", "PACE password", "That account's password."),
            new("azureClientId", "Azure client ID", "Service principal application ID, for Trusted Signing."),
            new("azureClientSecret", "Azure client secret", "That service principal's secret."),
            new("azureTenantId", "Azure tenant ID", "Your Entra tenant ID."),
            new("appleDevIdP12", "Apple Developer ID .p12", "Base64 of the exported certificate."),
            new("appleDevIdP12Password", "Apple .p12 password", "The password you set on the export."),
            new("appleAscIssuerId", "App Store Connect issuer ID", "For notarization."),
            new("appleAscKeyId", "App Store Connect key ID", "For notarization."),
            new("appleAscPrivateKey", "App Store Connect .p8", "Contents of the AuthKey_XXXX.p8 file."),
        ];

        TestGitHubCommand = new AsyncRelayCommand(_ => TestGitHubAsync());
        Refresh();
    }

    // -----------------------------------------------------------------------
    // The GitHub App identity.
    //
    // NEITHER OF THESE IS A SECRET. Both are shown openly in the GitHub UI and
    // both live in forge.json; it is the App's private key, above, that is
    // sensitive. They sit on this page because they identify the App whose key
    // that is — and because the macOS app puts them in exactly this place, and
    // the two apps are meant to teach the same layout.
    //
    // They previously had no editor anywhere in the Windows app while the
    // config demanded them, so the product could not be configured through its
    // own GUI at all.
    // -----------------------------------------------------------------------

    public string AppId
    {
        get => _configAccessor().GitHub.AppId;
        set
        {
            if (_configAccessor().GitHub.AppId == value) return;
            _configAccessor().GitHub.AppId = value.Trim();
            _saveConfig();
            OnPropertyChanged();
        }
    }

    public string InstallationId
    {
        get => _configAccessor().GitHub.InstallationId;
        set
        {
            if (_configAccessor().GitHub.InstallationId == value) return;
            _configAccessor().GitHub.InstallationId = value.Trim();
            _saveConfig();
            OnPropertyChanged();
        }
    }

    public ObservableCollection<CredentialField> Fields { get; }

    public AsyncRelayCommand TestGitHubCommand { get; }

    public string TestResult
    {
        get => _testResult;
        private set => SetProperty(ref _testResult, value);
    }

    public void Refresh()
    {
        foreach (CredentialField field in Fields)
        {
            field.IsStored = _secretStore.Has(field.KeyName);
            field.OnPropertyChangedPublic(nameof(CredentialField.StatusText));
        }
    }

    /// <summary>Stores a secret. The caller passes the value straight from a PasswordBox.</summary>
    public bool Store(string keyName, string value)
    {
        if (string.IsNullOrEmpty(value)) return false;
        bool stored = _secretStore.Write(keyName, value);
        Refresh();
        return stored;
    }

    public void Delete(string keyName)
    {
        _secretStore.Delete(keyName);
        Refresh();
    }

    private async Task TestGitHubAsync()
    {
        try
        {
            string slug = await _appService.TestAppCredentialsAsync(_configAccessor()).ConfigureAwait(true);
            TestResult = $"OK — GET /app succeeded. The App is '{slug}'.";
        }
        catch (Exception ex)
        {
            // GitHub's own message, verbatim: guessing at what a 401 means wastes
            // far more time than reading what GitHub actually said.
            TestResult = ex.Message;
        }
    }
}
