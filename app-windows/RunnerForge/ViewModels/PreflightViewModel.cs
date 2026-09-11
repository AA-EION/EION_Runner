using System.Collections.ObjectModel;
using System.Runtime.Versioning;
using RunnerForge.Models;
using RunnerForge.Services;

namespace RunnerForge.ViewModels;

/// <summary>Backs the Preflight page: what is missing, and what can be fixed here.</summary>
[SupportedOSPlatform("windows")]
public sealed class PreflightViewModel : ObservableObject
{
    private readonly PreflightService _preflightService;
    private readonly DockerService _dockerService;
    private readonly Func<ForgeConfig> _configAccessor;

    private bool _isChecking;
    private string _summary = "Not checked yet.";

    public PreflightViewModel(
        PreflightService preflightService, DockerService dockerService, Func<ForgeConfig> configAccessor)
    {
        _preflightService = preflightService;
        _dockerService = dockerService;
        _configAccessor = configAccessor;

        RunChecksCommand = new AsyncRelayCommand(_ => RunChecksAsync());
        FixCommand = new AsyncRelayCommand(parameter => FixAsync(parameter as PreflightCheck));
    }

    public ObservableCollection<PreflightCheck> Checks { get; } = [];

    public AsyncRelayCommand RunChecksCommand { get; }
    public AsyncRelayCommand FixCommand { get; }

    public bool IsChecking
    {
        get => _isChecking;
        private set => SetProperty(ref _isChecking, value);
    }

    public string Summary
    {
        get => _summary;
        private set => SetProperty(ref _summary, value);
    }

    /// <summary>True when at least one check is a hard block with no workaround.</summary>
    public bool HasHardBlock => Checks.Any(c => c.IsHardBlock);

    /// <summary>Classes that cannot run, so the Runners page can grey them out with a reason.</summary>
    public IReadOnlyDictionary<string, string> BlockedClasses =>
        Checks.Where(c => c.Status == PreflightStatus.Fail)
              .SelectMany(c => c.BlocksClasses.Select(classId => (classId, c.Name)))
              .GroupBy(x => x.classId)
              .ToDictionary(g => g.Key, g => string.Join("; ", g.Select(x => x.Name)));

    public async Task RunChecksAsync(CancellationToken cancellationToken = default)
    {
        IsChecking = true;
        Checks.Clear();
        Summary = "Checking…";

        try
        {
            IReadOnlyList<PreflightCheck> results =
                await _preflightService.RunAllAsync(_configAccessor(), cancellationToken).ConfigureAwait(true);

            foreach (PreflightCheck check in results) Checks.Add(check);

            int pass = results.Count(c => c.Status == PreflightStatus.Pass);
            int warn = results.Count(c => c.Status == PreflightStatus.Warn);
            int fail = results.Count(c => c.Status == PreflightStatus.Fail);

            Summary = $"Pass {pass}   Warn {warn}   Fail {fail}";

            if (results.Any(c => c.IsHardBlock))
            {
                Summary += "  —  a hard block is present; the affected classes cannot run on this machine.";
            }
        }
        catch (Exception ex)
        {
            Summary = "Preflight failed: " + ex.Message;
        }
        finally
        {
            IsChecking = false;
            OnPropertyChanged(nameof(HasHardBlock));
            OnPropertyChanged(nameof(BlockedClasses));
        }
    }

    private async Task FixAsync(PreflightCheck? check)
    {
        if (check is null || !check.AutoFixable) return;

        if (check.Name.StartsWith("Windows feature:", StringComparison.Ordinal))
        {
            string feature = check.Name["Windows feature:".Length..].Trim();
            await _preflightService.EnableFeatureAsync(feature).ConfigureAwait(true);
        }
        else if (check.Name.Contains("Windows containers mode", StringComparison.Ordinal))
        {
            await _dockerService.SwitchToWindowsContainersAsync().ConfigureAwait(true);
        }
        else if (check.Name.Contains("Sleep on AC", StringComparison.Ordinal))
        {
            await _preflightService.DisableSleepOnAcAsync().ConfigureAwait(true);
        }

        await RunChecksAsync().ConfigureAwait(true);
    }
}
