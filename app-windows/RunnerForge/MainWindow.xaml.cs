using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using RunnerForge.Services;
using RunnerForge.ViewModels;
using RunnerForge.Views;

namespace RunnerForge;

/// <summary>
/// The shell: a left nav and a content host. Pages are constructed once and
/// reused, so switching away and back does not lose in-progress state such as a
/// half-finished self-test.
/// </summary>
public partial class MainWindow : Window
{
    private readonly AppServices _services;
    private readonly Dictionary<string, UserControl> _pages = [];

    private PreflightViewModel? _preflightViewModel;
    private RunnersViewModel? _runnersViewModel;
    private SigningViewModel? _signingViewModel;

    public MainWindow()
    {
        InitializeComponent();

        _services = ((App)Application.Current).Services;

        VersionText.Text = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? "1.0.0";

        BuildPages();
        NavigationList.SelectedIndex = 0;

        _services.ConfigSaved += RefreshSetupBanner;
        RefreshSetupBanner();
    }

    /// <summary>
    /// Shows what is still unconfigured, and offers a one-click route to the
    /// page that fixes each item.
    /// </summary>
    /// <remarks>
    /// Re-run on every navigation, because the fix for a gap is on one of these
    /// pages and the banner must retire itself the moment the last one is
    /// filled in — an instruction that stays on screen after it has been
    /// followed reads as a bug.
    /// </remarks>
    public void RefreshSetupBanner()
    {
        IReadOnlyList<ConfigStore.SetupGap> gaps = ConfigStore.DescribeSetupGaps(_services.Config);

        SetupGapList.ItemsSource = gaps;
        SetupBanner.Visibility = gaps.Count == 0 ? Visibility.Collapsed : Visibility.Visible;

        SetupBannerHeading.Text = gaps.Count == 1
            ? "Setup: one more thing to fill in before runners can start."
            : $"Setup: {gaps.Count} things to fill in before runners can start.";
    }

    private void OnSetupGapClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string page }) return;

        foreach (object? entry in NavigationList.Items)
        {
            if (entry is ListBoxItem item && (item.Content?.ToString() ?? "") == page)
            {
                NavigationList.SelectedItem = item;
                return;
            }
        }
    }

    private void BuildPages()
    {
        Func<Models.ForgeConfig> config = () => _services.Config;
        Action save = _services.SaveConfig;

        _preflightViewModel = new PreflightViewModel(
            _services.PreflightService, _services.DockerService, config);

        _signingViewModel = new SigningViewModel(
            _services.SigningService, config, save, _services.ScriptsDirectory);

        _runnersViewModel = new RunnersViewModel(
            _services.RunnerSupervisor, _services.SelfTestService, config, save);

        _pages["Preflight"] = new PreflightPage { DataContext = _preflightViewModel };

        _pages["Credentials"] = new CredentialsPage
        {
            DataContext = new CredentialsViewModel(_services.SecretStore, _services.GitHubAppService, config, save),
        };

        _pages["Targets"] = new TargetsPage
        {
            DataContext = new TargetsViewModel(_services.GitHubAppService, config, save),
        };

        _pages["Runners"] = new RunnersPage { DataContext = _runnersViewModel };
        _pages["Signing"] = new SigningPage { DataContext = _signingViewModel };

        _pages["Export"] = new ExportPage
        {
            DataContext = new ExportViewModel(
                _services.TemplateRenderer, _services.SecretStore, config,
                // Export stays disabled while the selected signing mode has unmet
                // requirements: a workflow that cannot sign is worse than none.
                () => _services.SigningService.IsSatisfied(_services.Config.Signing.ModeEnum, _services.Config)),
        };

        _pages["Logs"] = new LogsPage { DataContext = new LogsViewModel(_services.LogBus) };

        _pages["Cleanup"] = new CleanupPage
        {
            DataContext = new CleanupViewModel(_services.SweeperService, config, save),
        };
    }

    private void OnNavigationChanged(object sender, SelectionChangedEventArgs e)
    {
        if (NavigationList.SelectedItem is not ListBoxItem item) return;

        string name = item.Content?.ToString() ?? "Preflight";
        if (!_pages.TryGetValue(name, out UserControl? page)) return;

        PageHost.Content = page;
        RefreshSetupBanner();

        // Pages that reflect live state refresh on entry rather than polling.
        switch (name)
        {
            case "Preflight":
                _ = _preflightViewModel?.RunChecksAsync();
                break;

            case "Runners":
                _runnersViewModel?.Reload();
                if (_preflightViewModel is not null)
                {
                    _runnersViewModel?.ApplyPreflightBlocks(_preflightViewModel.BlockedClasses);
                }
                break;

            case "Signing":
                _signingViewModel?.RefreshRequirements();
                break;

            case "Cleanup":
                if (page.DataContext is CleanupViewModel cleanup) _ = cleanup.RefreshAsync();
                break;
        }
    }
}
