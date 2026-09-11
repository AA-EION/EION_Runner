using System.Collections.ObjectModel;
using RunnerForge.Models;
using RunnerForge.Services;

namespace RunnerForge.ViewModels;

/// <summary>Backs the Signing page: three modes with a live requirement checklist.</summary>
public sealed class SigningViewModel : ObservableObject
{
    private readonly SigningService _signingService;
    private readonly Func<ForgeConfig> _configAccessor;
    private readonly Action _saveConfig;

    private SigningMode _selectedMode;

    public SigningViewModel(SigningService signingService, Func<ForgeConfig> configAccessor, Action saveConfig)
    {
        _signingService = signingService;
        _configAccessor = configAccessor;
        _saveConfig = saveConfig;
        Reload();
    }

    public ObservableCollection<SigningRequirement> Requirements { get; } = [];

    public IReadOnlyList<SigningMode> AvailableModes { get; } =
        [SigningMode.Cloud, SigningMode.WindowsIlok, SigningMode.MacosIlok];

    public SigningMode SelectedMode
    {
        get => _selectedMode;
        set
        {
            if (!SetProperty(ref _selectedMode, value)) return;
            _configAccessor().Signing.ModeEnum = value;
            _saveConfig();
            RefreshRequirements();
        }
    }

    /// <summary>
    /// True when the selected mode's requirements are not all met. Selecting such
    /// a mode is allowed — people configure before they install — but Export is
    /// disabled, because emitting a workflow that cannot sign is worse than
    /// refusing to emit one.
    /// </summary>
    public bool HasUnmetRequirements => Requirements.Any(r => !r.Satisfied);

    public string WarningText => HasUnmetRequirements
        ? $"{Requirements.Count(r => !r.Satisfied)} requirement(s) for "
          + $"{SelectedMode.ToDisplayName()} are not met. Export stays disabled until they are."
        : "";

    // --- Windows Authenticode ------------------------------------------------
    public IReadOnlyList<WindowsSigningProvider> WindowsProviders { get; } =
        [WindowsSigningProvider.None, WindowsSigningProvider.AzureTrustedSigning];

    public WindowsSigningProvider WindowsProvider
    {
        get => SigningModeExtensions.ProviderFromConfigValue(_configAccessor().Signing.Windows.Provider);
        set
        {
            _configAccessor().Signing.Windows.Provider = value.ToConfigValue();
            _saveConfig();
            OnPropertyChanged();
        }
    }

    public string AzureEndpoint
    {
        get => _configAccessor().Signing.Windows.AzureEndpoint;
        set { _configAccessor().Signing.Windows.AzureEndpoint = value; _saveConfig(); OnPropertyChanged(); }
    }

    public string AzureAccount
    {
        get => _configAccessor().Signing.Windows.AzureAccount;
        set { _configAccessor().Signing.Windows.AzureAccount = value; _saveConfig(); OnPropertyChanged(); }
    }

    public string AzureProfile
    {
        get => _configAccessor().Signing.Windows.AzureProfile;
        set { _configAccessor().Signing.Windows.AzureProfile = value; _saveConfig(); OnPropertyChanged(); }
    }

    // --- macOS Developer ID --------------------------------------------------
    public string AppleTeamId
    {
        get => _configAccessor().Signing.Macos.TeamId;
        set { _configAccessor().Signing.Macos.TeamId = value; _saveConfig(); OnPropertyChanged(); }
    }

    /// <summary>A certificate common name, not a key. Safe to keep in forge.json.</summary>
    public string DevIdAppIdentity
    {
        get => _configAccessor().Signing.Macos.DevIdAppIdentity;
        set { _configAccessor().Signing.Macos.DevIdAppIdentity = value; _saveConfig(); OnPropertyChanged(); }
    }

    public string DevIdInstallerIdentity
    {
        get => _configAccessor().Signing.Macos.DevIdInstallerIdentity;
        set { _configAccessor().Signing.Macos.DevIdInstallerIdentity = value; _saveConfig(); OnPropertyChanged(); }
    }

    /// <summary>
    /// Stapling follows notarization. Turning notarization off means the artifact
    /// fails Gatekeeper on any machine but the one that built it.
    /// </summary>
    public bool Notarize
    {
        get => _configAccessor().Signing.Macos.Notarize;
        set { _configAccessor().Signing.Macos.Notarize = value; _saveConfig(); OnPropertyChanged(); }
    }

    // --- PACE ----------------------------------------------------------------
    public string PaceAccount
    {
        get => _configAccessor().Signing.PaceAccount;
        set { _configAccessor().Signing.PaceAccount = value; _saveConfig(); RefreshRequirements(); OnPropertyChanged(); }
    }

    public string PaceWcGuid
    {
        get => _configAccessor().Signing.PaceWcGuid;
        set { _configAccessor().Signing.PaceWcGuid = value; _saveConfig(); RefreshRequirements(); OnPropertyChanged(); }
    }

    public string PaceSignId
    {
        get => _configAccessor().Signing.PaceSignId;
        set { _configAccessor().Signing.PaceSignId = value; _saveConfig(); RefreshRequirements(); OnPropertyChanged(); }
    }

    public void Reload()
    {
        _selectedMode = _configAccessor().Signing.ModeEnum;
        OnPropertyChanged(nameof(SelectedMode));
        RefreshRequirements();
    }

    public void RefreshRequirements()
    {
        Requirements.Clear();
        foreach (SigningRequirement requirement in _signingService.RequirementsFor(SelectedMode, _configAccessor()))
        {
            Requirements.Add(requirement);
        }

        OnPropertyChanged(nameof(HasUnmetRequirements));
        OnPropertyChanged(nameof(WarningText));
    }
}
