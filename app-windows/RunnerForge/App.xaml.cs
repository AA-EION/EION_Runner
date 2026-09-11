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

/// <summary>
/// Inverts a bool. Used where a control is enabled EXCEPT while something is
/// running — binding IsEnabled directly to an IsBusy flag gets that backwards.
/// </summary>
public sealed class InverseBoolConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is not bool flag || !flag;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is not bool flag || !flag;
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

        // The scripts are program files of this product, installed beside the
        // executable by the MSI. Falling back to the working directory keeps a
        // developer running from a checkout working too.
        string beside = Path.Combine(AppContext.BaseDirectory, "scripts");
        ScriptsDirectory = Directory.Exists(beside)
            ? beside
            : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "scripts"));
    }

    /// <summary>Where the shipped .ps1 and .sh scripts live.</summary>
    public string ScriptsDirectory { get; }

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

        // Report a crash instead of vanishing. An unhandled exception on the UI
        // thread otherwise kills the process with no window and no message, which
        // is indistinguishable from "the app does nothing".
        DispatcherUnhandledException += OnDispatcherUnhandledException;

        base.OnStartup(e);

        // ---------------------------------------------------------------
        // Show the window.
        //
        // This is done HERE and not with StartupUri in App.xaml, because
        // MainWindow's constructor reads ((App)Application.Current).Services and
        // that has to be assigned first. One code path, in the right order,
        // rather than two that can disagree.
        //
        // Its absence was a real defect: the app launched, built its services,
        // logged "Runner Forge started" and then sat there with no window,
        // because nothing in the process ever constructed MainWindow. It built,
        // published and packaged perfectly the whole time.
        // ---------------------------------------------------------------
        try
        {
            var window = new MainWindow();
            MainWindow = window;
            window.Show();
        }
        catch (Exception ex)
        {
            Services.LogBus.Error("app", $"the main window could not be created: {ex}");
            MessageBox.Show(
                "Runner Forge could not open its main window.\n\n"
                + ex.Message
                + "\n\nConfiguration lives at:\n"
                + ConfigStore.DefaultConfigPath,
                "Runner Forge", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    private void OnDispatcherUnhandledException(
        object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
    {
        Services?.LogBus.Error("app", $"unhandled: {e.Exception}");

        MessageBox.Show(
            $"Runner Forge hit an unexpected error.\n\n{e.Exception.Message}\n\n"
            + "The app will stay open. The full error is on the Logs page.",
            "Runner Forge", MessageBoxButton.OK, MessageBoxImage.Error);

        // Handled, so one bad page does not take the whole app down with it.
        e.Handled = true;
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
