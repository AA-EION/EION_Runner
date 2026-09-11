using System.Globalization;
using System.Net.Http;
using System.Threading;
using System.Windows;
using System.Windows.Data;
using RunnerForge.Models;
using RunnerForge.Services;

namespace RunnerForge;

/// <summary>Collapses a false to Collapsed, so a panel disappears rather than leaving a gap.</summary>
public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is true ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is Visibility.Visible;
}

/// <summary>Renders a requirement's satisfied flag as a tick or a cross.</summary>
public sealed class BoolToTickConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is true ? "✓" : "✗";

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

/// <summary>
/// The service container. Hand-rolled rather than a DI framework: this app has a
/// fixed, known set of services and wiring them explicitly is shorter than
/// configuring a container to do it.
/// </summary>
public sealed class AppServices
{
    public AppServices()
    {
        LogBus = new LogBus();
        HttpClient = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        ProcessRunner = new ProcessRunner(LogBus);
        ConfigStore = new ConfigStore(LogBus);
        SecretStore = new SecretStore(LogBus);
        DockerService = new DockerService(LogBus, ProcessRunner);
        GitHubAppService = new GitHubAppService(LogBus, SecretStore, HttpClient);
        GitHubActionsService = new GitHubActionsService(LogBus, GitHubAppService, HttpClient);
        ReaperService = new ReaperService(LogBus, ProcessRunner);
        SweeperService = new SweeperService(LogBus, ProcessRunner);
        PreflightService = new PreflightService(LogBus, ProcessRunner, DockerService, HttpClient);
        SigningService = new SigningService(LogBus, ProcessRunner, SecretStore);
        TemplateRenderer = new TemplateRenderer();
        RunnerSupervisor = new RunnerSupervisor(
            LogBus, DockerService, GitHubAppService, GitHubActionsService, ReaperService);
        SelfTestService = new SelfTestService(
            LogBus, ConfigStore, GitHubActionsService, ReaperService, SweeperService);

        Config = ConfigStore.Load();
    }

    public LogBus LogBus { get; }
    public HttpClient HttpClient { get; }
    public ProcessRunner ProcessRunner { get; }
    public ConfigStore ConfigStore { get; }
    public SecretStore SecretStore { get; }
    public DockerService DockerService { get; }
    public GitHubAppService GitHubAppService { get; }
    public GitHubActionsService GitHubActionsService { get; }
    public ReaperService ReaperService { get; }
    public SweeperService SweeperService { get; }
    public PreflightService PreflightService { get; }
    public SigningService SigningService { get; }
    public TemplateRenderer TemplateRenderer { get; }
    public RunnerSupervisor RunnerSupervisor { get; }
    public SelfTestService SelfTestService { get; }

    public ForgeConfig Config { get; set; }

    public void SaveConfig() => ConfigStore.Save(Config);
}

public partial class App : Application
{
    /// <summary>
    /// One instance per machine. Two copies fighting over the same runners and
    /// the same work directory would corrupt state.json.
    /// </summary>
    private const string SingleInstanceMutexName = @"Global\RunnerForge";

    private Mutex? _singleInstanceMutex;

    public AppServices Services { get; private set; } = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        _singleInstanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out bool createdNew);

        if (!createdNew)
        {
            MessageBox.Show(
                "Runner Forge is already running. Two copies would fight over the same runners and the same "
                + "work directory.",
                "Runner Forge", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        Services = new AppServices();
        Services.LogBus.Info("app", "Runner Forge started");

        base.OnStartup(e);
    }

    /// <summary>
    /// Close behaviour: drain runners, reap, sweep — never exit silently while a
    /// build is in flight.
    /// </summary>
    protected override void OnExit(ExitEventArgs e)
    {
        try
        {
            if (Services is not null)
            {
                Services.LogBus.Info("app", "closing: draining runners");

                int timeoutMinutes = Services.Config.Runners.Count > 0
                    ? Services.Config.Runners.Max(r => r.JobTimeoutMinutes)
                    : 60;

                Services.RunnerSupervisor
                    .DrainAsync(TimeSpan.FromMinutes(timeoutMinutes))
                    .GetAwaiter().GetResult();

                Services.LogBus.Info("app", "closing: reaping");
                Services.ReaperService
                    .ReapAsync(Services.Config, [], [])
                    .GetAwaiter().GetResult();

                if (Services.Config.Retention.PurgeOnExit)
                {
                    Services.LogBus.Info("app", "closing: sweeping");
                    Services.SweeperService
                        .PurgeAsync(Services.Config)
                        .GetAwaiter().GetResult();
                }

                Services.HttpClient.Dispose();
            }
        }
        catch (Exception ex)
        {
            // Closing must not hang on an error; the Reaper's watchdog picks up
            // anything left behind on the next launch.
            Services?.LogBus.Error("app", $"shutdown: {ex.Message}");
        }
        finally
        {
            _singleInstanceMutex?.ReleaseMutex();
            _singleInstanceMutex?.Dispose();
        }

        base.OnExit(e);
    }
}
