using System.Diagnostics;
using System.Reflection;
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
        ReaperService = new ReaperService(LogBus, ProcessRunner, DockerService);
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

    /// <summary>
    /// Raised after every save. The setup banner listens, so filling in the last
    /// missing field retires it immediately rather than on the next navigation —
    /// an instruction that stays on screen after it has been followed reads as a
    /// bug.
    /// </summary>
    public event Action? ConfigSaved;

    public void SaveConfig()
    {
        ConfigStore.Save(Config);
        ConfigSaved?.Invoke();
    }
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
        // ---------------------------------------------------------------
        // ORDER MATTERS HERE, and it is the reason this method looks the way
        // it does.
        //
        // Previously the service container was built FIRST and the exception
        // handlers were attached after it. Anything that threw while building
        // services — and building services touches the filesystem, so it can —
        // killed the process before any handler existed: no window, no dialog,
        // nothing. "No UI, no errors" is precisely what that looks like from
        // the outside, and it is indistinguishable from the two earlier bugs
        // that produced the same report (TROUBLESHOOTING #19, #20).
        //
        // So now: breadcrumbs first, handlers second, everything that can fail
        // third, and every one of those inside a try/catch that SAYS SO.
        // ---------------------------------------------------------------

        // Identify the build before anything else can go wrong. The first
        // question on any "it does not work" report is "which build is that",
        // and it has to be answerable from the log alone.
        LogBus.WriteBootstrap(LogLevel.Info, "app", new string('-', 60));
        LogBus.WriteBootstrap(LogLevel.Info, "app",
            $"Runner Forge {ThisVersion} starting — {Environment.OSVersion}, "
            + $"{(Environment.Is64BitProcess ? "64-bit" : "32-bit")}, "
            + $"session {Process.GetCurrentProcess().SessionId}, user {Environment.UserName}");
        LogBus.WriteBootstrap(LogLevel.Info, "app", $"exe:    {Environment.ProcessPath}");
        LogBus.WriteBootstrap(LogLevel.Info, "app", $"log:    {LogBus.DefaultLogPath}");
        LogBus.WriteBootstrap(LogLevel.Info, "app", $"config: {ConfigStore.DefaultConfigPath}");

        // Report a crash instead of vanishing. Attached BEFORE anything that
        // can throw, which was the whole defect above.
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnAppDomainUnhandledException;

        base.OnStartup(e);

        _singleInstanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out bool createdNew);

        if (!createdNew)
        {
            // Logged as well as shown: if the dialog is dismissed or never seen,
            // the log still says why this launch produced no window.
            LogBus.WriteBootstrap(LogLevel.Warning, "app",
                "another Runner Forge already holds the single-instance mutex; exiting. "
                + "If no window is visible, a previous copy is still running — end "
                + "RunnerForge.exe in Task Manager and start again.");

            MessageBox.Show(
                "Runner Forge is already running. Two copies would fight over the same runners and the same "
                + "work directory.\n\n"
                + "If you cannot see its window, a previous copy is still running in the background: end "
                + "RunnerForge.exe in Task Manager and start Runner Forge again.",
                "Runner Forge", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        // ---------------------------------------------------------------
        // Build the services. This touches the filesystem — it creates and
        // writes %ProgramData%\RunnerForge\forge.json — so it can genuinely
        // fail on a real machine in ways a CI runner never sees, an ACL on
        // that folder being the obvious one.
        // ---------------------------------------------------------------
        try
        {
            Services = new AppServices();
        }
        catch (Exception ex)
        {
            LogBus.WriteBootstrap(LogLevel.Error, "app", $"could not start: {ex}");
            MessageBox.Show(
                "Runner Forge could not start.\n\n"
                + ex.Message
                + "\n\nThe full error is in the log at:\n"
                + LogBus.DefaultLogPath,
                "Runner Forge", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }

        Services.LogBus.Info("app", $"services ready; config {Services.ConfigStore.ConfigPath}");

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
            Services.LogBus.Info("app", "constructing the main window");
            var window = new MainWindow();
            MainWindow = window;

            Services.LogBus.Info("app", "showing the main window");
            window.Show();

            // Activate() as well as Show(): a window that is open but behind
            // everything else is, to the person looking at the screen, the same
            // as no window at all.
            window.Activate();

            Services.LogBus.Info("app",
                $"the main window is open — {window.Width}x{window.Height} at "
                + $"{window.Left},{window.Top}, visible {window.IsVisible}");
        }
        catch (Exception ex)
        {
            Services.LogBus.Error("app", $"the main window could not be created: {ex}");
            MessageBox.Show(
                "Runner Forge could not open its main window.\n\n"
                + ex.Message
                + "\n\nThe full error is in the log at:\n"
                + LogBus.DefaultLogPath,
                "Runner Forge", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    /// <summary>The build, as the log and the About line report it.</summary>
    private static string ThisVersion =>
        Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? "unknown";

    /// <summary>
    /// The last line of defence. An exception on a non-UI thread does not reach
    /// DispatcherUnhandledException, and by default takes the process down with
    /// no message at all.
    /// </summary>
    private void OnAppDomainUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        string text = e.ExceptionObject is Exception ex ? ex.ToString() : e.ExceptionObject.ToString() ?? "unknown";

        if (Services is not null) Services.LogBus.Error("app", $"unhandled (non-UI thread): {text}");
        else LogBus.WriteBootstrap(LogLevel.Error, "app", $"unhandled (non-UI thread): {text}");
    }

    /// <summary>True while a MessageBox from the handler below is on screen.</summary>
    private bool _reportingError;

    /// <summary>Exception messages already shown once. Kept so a repeat is silent.</summary>
    private readonly HashSet<string> _reportedErrors = [];

    private void OnDispatcherUnhandledException(
        object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
    {
        // Logging is unconditional: every occurrence goes to the file, however
        // many there are, because the count is itself diagnostic.
        Services?.LogBus.Error("app", $"unhandled: {e.Exception}");

        // Handled, so one bad page does not take the whole app down with it.
        e.Handled = true;

        // ---------------------------------------------------------------
        // Everything below exists because reporting an error can BE the
        // crash. MessageBox.Show pumps a nested message loop, and that loop
        // runs the very dispatcher work that threw — the binding engine, the
        // layout pass — on top of the stack frames already there. An
        // exception that recurs (a broken binding recurs once per binding,
        // forever) therefore stacks a dialog on a dialog on a dialog until
        // the thread runs out of stack and Windows kills the process with
        // 0xC00000FD, STATUS_STACK_OVERFLOW. That happened: 33 reports, then
        // a stack overflow, and the modal dialogs meant the user saw neither
        // the app nor the error.
        //
        // So: never re-enter, and never show the same message twice.
        // ---------------------------------------------------------------
        if (_reportingError) return;

        string message = e.Exception.Message;
        if (!_reportedErrors.Add(message))
        {
            return;
        }

        _reportingError = true;
        try
        {
            MessageBox.Show(
                $"Runner Forge hit an unexpected error.\n\n{message}\n\n"
                + "The app will stay open. The full error is on the Logs page and in:\n"
                + LogBus.DefaultLogPath,
                "Runner Forge", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _reportingError = false;
        }
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
