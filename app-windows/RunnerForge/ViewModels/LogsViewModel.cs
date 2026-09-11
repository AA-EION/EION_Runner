using System.Collections.ObjectModel;
using RunnerForge.Services;

namespace RunnerForge.ViewModels;

/// <summary>Backs the Logs page. Everything shown here has already been redacted.</summary>
public sealed class LogsViewModel : ObservableObject
{
    private readonly LogBus _logBus;
    private string _sourceFilter = "";
    private LogLevel _minimumLevel = LogLevel.Info;

    public LogsViewModel(LogBus logBus)
    {
        _logBus = logBus;
        _logBus.EntryAdded += OnEntryAdded;

        ClearCommand = new RelayCommand(_ => { _logBus.Clear(); Entries.Clear(); });

        foreach (LogEntry entry in _logBus.Snapshot()) Entries.Add(entry);
    }

    /// <summary>Bound to a virtualized list: a long build produces a lot of lines.</summary>
    public ObservableCollection<LogEntry> Entries { get; } = [];

    public RelayCommand ClearCommand { get; }

    public IReadOnlyList<LogLevel> Levels { get; } =
        [LogLevel.Debug, LogLevel.Info, LogLevel.Warning, LogLevel.Error];

    public string SourceFilter
    {
        get => _sourceFilter;
        set { SetProperty(ref _sourceFilter, value); Refilter(); }
    }

    public LogLevel MinimumLevel
    {
        get => _minimumLevel;
        set { SetProperty(ref _minimumLevel, value); Refilter(); }
    }

    /// <summary>Already redacted, so it is safe to put on the clipboard or in a file.</summary>
    public string CopyText() => string.Join(Environment.NewLine, Entries.Select(e => e.ToString()));

    public void SaveTo(string path) => File.WriteAllText(path, CopyText());

    private void Refilter()
    {
        Entries.Clear();
        foreach (LogEntry entry in _logBus.Snapshot().Where(Matches)) Entries.Add(entry);
    }

    private bool Matches(LogEntry entry) =>
        entry.Level >= MinimumLevel
        && (string.IsNullOrWhiteSpace(SourceFilter)
            || entry.Source.Contains(SourceFilter, StringComparison.OrdinalIgnoreCase));

    private void OnEntryAdded(LogEntry entry)
    {
        if (!Matches(entry)) return;

        // The UI thread owns the collection; the callback can arrive on any
        // thread, so marshal.
        System.Windows.Application.Current?.Dispatcher.Invoke(() =>
        {
            Entries.Add(entry);
            while (Entries.Count > 5000) Entries.RemoveAt(0);
        });
    }
}
