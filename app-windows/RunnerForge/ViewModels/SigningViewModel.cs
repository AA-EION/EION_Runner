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
    private readonly string _scriptsDirectory;

    private SigningMode _selectedMode;

    public SigningViewModel(
        SigningService signingService, Func<ForgeConfig> configAccessor, Action saveConfig,
        string scriptsDirectory)
    {
        _signingService = signingService;
        _configAccessor = configAccessor;
        _saveConfig = saveConfig;
        _scriptsDirectory = scriptsDirectory;

        RefreshCertificatesCommand = new RelayCommand(_ => RefreshCertificates());
        GenerateSelfSignedCommand = new AsyncRelayCommand(
            _ => GenerateSelfSignedAsync(_scriptsDirectory),
            _ => !IsGenerating);

        Reload();
    }

    public RelayCommand RefreshCertificatesCommand { get; }
    public AsyncRelayCommand GenerateSelfSignedCommand { get; }

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

    public string PaceCustomerNumber
    {
        get => _configAccessor().Signing.PaceCustomerNumber;
        set { _configAccessor().Signing.PaceCustomerNumber = value; _saveConfig(); RefreshRequirements(); OnPropertyChanged(); }
    }

    public string PaceCustomerName
    {
        get => _configAccessor().Signing.PaceCustomerName;
        set { _configAccessor().Signing.PaceCustomerName = value; _saveConfig(); RefreshRequirements(); OnPropertyChanged(); }
    }

    public string PaceSignId
    {
        get => _configAccessor().Signing.PaceSignId;
        set { _configAccessor().Signing.PaceSignId = value; _saveConfig(); RefreshRequirements(); OnPropertyChanged(); }
    }

    // -----------------------------------------------------------------------
    // Certificates
    //
    // Offered as a LIST rather than a text field, because on Windows --signid
    // takes the 40-character thumbprint while on macOS it takes the subject
    // name. Asking a human to know which, and to retype 40 hex characters
    // without error, is how this step goes wrong.
    // -----------------------------------------------------------------------

    public ObservableCollection<SigningService.SigningCertificate> Certificates { get; } = [];

    private SigningService.SigningCertificate? _selectedCertificate;

    public SigningService.SigningCertificate? SelectedCertificate
    {
        get => _selectedCertificate;
        set
        {
            _selectedCertificate = value;
            if (value is not null)
            {
                ForgeConfig config = _configAccessor();
                config.Signing.PaceSignId = value.Thumbprint;
                // Recording self-signed here means the scripts and the UI never
                // have to re-derive it later, or disagree about it.
                config.Signing.PaceSelfSigned = value.SelfSigned;
                _saveConfig();
                OnPropertyChanged(nameof(PaceSignId));
                RefreshRequirements();
            }
            OnPropertyChanged();
        }
    }

    public string? WraptoolPath { get; private set; }

    public string WraptoolStatus => WraptoolPath ?? "wraptool.exe not found";

    public bool WraptoolFound => WraptoolPath is not null;

    private string _newCertificateSubject = "";

    public string NewCertificateSubject
    {
        get => _newCertificateSubject;
        set { _newCertificateSubject = value; OnPropertyChanged(); }
    }

    private string? _generateMessage;

    public string? GenerateMessage
    {
        get => _generateMessage;
        private set { _generateMessage = value; OnPropertyChanged(); }
    }

    private bool _isGenerating;

    public bool IsGenerating
    {
        get => _isGenerating;
        private set { _isGenerating = value; OnPropertyChanged(); }
    }

    /// <summary>Re-reads the certificate stores and re-locates wraptool.</summary>
    public void RefreshCertificates()
    {
        WraptoolPath = SigningService.FindWraptool();
        OnPropertyChanged(nameof(WraptoolPath));
        OnPropertyChanged(nameof(WraptoolStatus));
        OnPropertyChanged(nameof(WraptoolFound));

        Certificates.Clear();
        string configured = _configAccessor().Signing.PaceSignId;

        foreach (SigningService.SigningCertificate certificate in _signingService.ListSigningCertificates())
        {
            Certificates.Add(certificate);
            if (string.Equals(certificate.Thumbprint, configured, StringComparison.OrdinalIgnoreCase))
            {
                _selectedCertificate = certificate;
            }
        }

        OnPropertyChanged(nameof(SelectedCertificate));
    }

    /// <summary>
    /// Creates a self-signed certificate so somebody with no certificate at all
    /// does not have to leave the app, read Microsoft's docs and come back.
    /// </summary>
    public async Task GenerateSelfSignedAsync(string scriptsDirectory)
    {
        string subject = NewCertificateSubject.Trim();
        if (subject.Length == 0)
        {
            GenerateMessage = "Give the certificate a name first. It becomes the certificate subject.";
            return;
        }
        if (IsGenerating) return;

        IsGenerating = true;
        try
        {
            bool ok = await _signingService
                .GenerateSelfSignedCertificateAsync(subject, scriptsDirectory)
                .ConfigureAwait(true);

            if (ok)
            {
                RefreshCertificates();
                SelectedCertificate = Certificates.FirstOrDefault(c => c.Subject == $"CN={subject}");
                NewCertificateSubject = "";
                GenerateMessage =
                    $"Created \"{subject}\" and selected it. It is a SELF-SIGNED certificate: good for "
                    + "testing in Pro Tools, not for distribution. See docs/SIGNING.md.";
            }
            else
            {
                GenerateMessage = "Could not create the certificate. See the Logs page.";
            }
        }
        finally
        {
            IsGenerating = false;
        }
    }

    public void Reload()
    {
        _selectedMode = _configAccessor().Signing.ModeEnum;
        OnPropertyChanged(nameof(SelectedMode));
        RefreshRequirements();
    }

    public void RefreshRequirements()
    {
        if (WraptoolPath is null && Certificates.Count == 0) RefreshCertificates();

        Requirements.Clear();
        foreach (SigningRequirement requirement in _signingService.RequirementsFor(SelectedMode, _configAccessor()))
        {
            Requirements.Add(requirement);
        }

        OnPropertyChanged(nameof(HasUnmetRequirements));
        OnPropertyChanged(nameof(WarningText));
    }
}
