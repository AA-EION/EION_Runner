using System.Collections.ObjectModel;
using RunnerForge.Models;
using RunnerForge.Services;

namespace RunnerForge.ViewModels;

/// <summary>Backs the Cleanup page: two explicit columns and a real byte count.</summary>
public sealed class CleanupViewModel : ObservableObject
{
    private readonly SweeperService _sweeperService;
    private readonly Func<ForgeConfig> _configAccessor;
    private readonly Action _saveConfig;

    private string _totalReclaimable = "—";
    private string _totalKept = "—";
    private string _status = "";

    public CleanupViewModel(SweeperService sweeperService, Func<ForgeConfig> configAccessor, Action saveConfig)
    {
        _sweeperService = sweeperService;
        _configAccessor = configAccessor;
        _saveConfig = saveConfig;

        RefreshCommand = new AsyncRelayCommand(_ => RefreshAsync());
        PurgeCommand = new AsyncRelayCommand(_ => PurgeAsync());
    }

    public ObservableCollection<DiskUsageItem> KeepItems { get; } = [];
    public ObservableCollection<DiskUsageItem> PurgeItems { get; } = [];

    public AsyncRelayCommand RefreshCommand { get; }
    public AsyncRelayCommand PurgeCommand { get; }

    public string TotalReclaimable
    {
        get => _totalReclaimable;
        private set => SetProperty(ref _totalReclaimable, value);
    }

    public string TotalKept
    {
        get => _totalKept;
        private set => SetProperty(ref _totalKept, value);
    }

    public string Status
    {
        get => _status;
        private set => SetProperty(ref _status, value);
    }

    /// <summary>Explains why KEEP is not clutter, so nobody "helpfully" empties it.</summary>
    public string KeepExplanation =>
        "These are kept on purpose. They are what makes the next run fast: base images take tens of "
        + "minutes to rebuild, and the cache volumes are the difference between reusing a JUCE clone and "
        + "downloading it again on every build.";

    public bool PurgeOnExit
    {
        get => _configAccessor().Retention.PurgeOnExit;
        set { _configAccessor().Retention.PurgeOnExit = value; _saveConfig(); OnPropertyChanged(); }
    }

    public async Task RefreshAsync()
    {
        Status = "Surveying…";
        try
        {
            DiskUsage usage = await _sweeperService.SurveyAsync(_configAccessor()).ConfigureAwait(true);

            KeepItems.Clear();
            foreach (DiskUsageItem item in usage.Keep) KeepItems.Add(item);

            PurgeItems.Clear();
            foreach (DiskUsageItem item in usage.Purge) PurgeItems.Add(item);

            TotalKept = usage.HumanKeepBytes;
            TotalReclaimable = usage.HumanReclaimableBytes;
            Status = "";
        }
        catch (Exception ex)
        {
            Status = ex.Message;
        }
    }

    private async Task PurgeAsync()
    {
        Status = "Purging…";
        try
        {
            long reclaimed = await _sweeperService.PurgeAsync(_configAccessor()).ConfigureAwait(true);
            Status = $"Reclaimed {DiskUsageItem.FormatBytes(reclaimed)}.";
            await RefreshAsync().ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            Status = ex.Message;
        }
    }
}
