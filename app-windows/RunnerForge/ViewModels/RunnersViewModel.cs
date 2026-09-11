using System.Collections.ObjectModel;
using RunnerForge.Models;
using RunnerForge.Services;

namespace RunnerForge.ViewModels;

/// <summary>One runner-class card on the Runners page.</summary>
public sealed class RunnerCard(RunnerClass runnerClass) : ObservableObject
{
    private bool _enabled;
    private int _replicas = runnerClass.DefaultReplicas;
    private string _blockedReason = "";

    public RunnerClass Class { get; } = runnerClass;

    public string DisplayName => Class.DisplayName;
    public string ClassId => Class.ClassId;
    public string LabelsText => string.Join(", ", Class.Labels);

    /// <summary>Shown on the card so the design decision is visible, not mysterious.</summary>
    public string? NotContainerizedReason => Class.NotContainerizedReason;

    public bool ReplicasEnabled => !Class.ReplicasAreFixed && IsAvailable;

    public bool Enabled
    {
        get => _enabled;
        set => SetProperty(ref _enabled, value);
    }

    public int Replicas
    {
        get => _replicas;
        set => SetProperty(ref _replicas, Math.Clamp(value, Class.MinReplicas, Class.MaxReplicas));
    }

    /// <summary>Non-empty when preflight says this class cannot run here.</summary>
    public string BlockedReason
    {
        get => _blockedReason;
        set
        {
            if (!SetProperty(ref _blockedReason, value)) return;
            OnPropertyChanged(nameof(IsAvailable));
            OnPropertyChanged(nameof(ReplicasEnabled));
        }
    }

    public bool IsAvailable => string.IsNullOrEmpty(BlockedReason);

    public ObservableCollection<ReplicaStatus> Replicas_ { get; } = [];
}

/// <summary>Backs the Runners page.</summary>
public sealed class RunnersViewModel : ObservableObject
{
    private readonly RunnerSupervisor _supervisor;
    private readonly SelfTestService _selfTestService;
    private readonly Func<ForgeConfig> _configAccessor;
    private readonly Action _saveConfig;

    private string _selfTestStatus = "";
    private SelfTestResult? _lastProof;

    public RunnersViewModel(
        RunnerSupervisor supervisor,
        SelfTestService selfTestService,
        Func<ForgeConfig> configAccessor,
        Action saveConfig)
    {
        _supervisor = supervisor;
        _selfTestService = selfTestService;
        _configAccessor = configAccessor;
        _saveConfig = saveConfig;

        foreach (RunnerClass runnerClass in RunnerClass.All) Cards.Add(new RunnerCard(runnerClass));

        StartCommand = new AsyncRelayCommand(p => StartAsync(p as RunnerCard));
        StopCommand = new AsyncRelayCommand(p => StopAsync(p as RunnerCard));
        RunSelfTestCommand = new AsyncRelayCommand(_ => RunSelfTestAsync());
        AcknowledgeStraysCommand = new RelayCommand(_ =>
        {
            _supervisor.AcknowledgeStraySurvivors();
            OnPropertyChanged(nameof(StrayBannerVisible));
            OnPropertyChanged(nameof(StrayBannerText));
        });

        _supervisor.StatusChanged += OnSupervisorStatusChanged;
        Reload();
    }

    public ObservableCollection<RunnerCard> Cards { get; } = [];

    public AsyncRelayCommand StartCommand { get; }
    public AsyncRelayCommand StopCommand { get; }
    public AsyncRelayCommand RunSelfTestCommand { get; }
    public RelayCommand AcknowledgeStraysCommand { get; }

    public string SelfTestStatus
    {
        get => _selfTestStatus;
        private set => SetProperty(ref _selfTestStatus, value);
    }

    public SelfTestResult? LastProof
    {
        get => _lastProof;
        private set
        {
            SetProperty(ref _lastProof, value);
            OnPropertyChanged(nameof(LastProofBadge));
            OnPropertyChanged(nameof(LastProofDetail));
        }
    }

    /// <summary>Green or red, so the user sees at a glance whether this setup is known-good.</summary>
    public string LastProofBadge => LastProof is null
        ? "never verified"
        : LastProof.Passed ? "PASS" : "FAIL";

    public string LastProofDetail => LastProof is null
        ? "Run the self-test to prove this setup works end to end."
        : $"run {LastProof.RunId} · {LastProof.StartedAt.LocalDateTime:g} · {LastProof.DurationSeconds}s · "
          + $"{LastProof.Artifacts.Count(a => a.Verdict == "pass")}/{LastProof.Artifacts.Count} artifacts";

    /// <summary>The Reaper found survivors; new runners are refused until acknowledged.</summary>
    public bool StrayBannerVisible => _supervisor.BlockedByStraySurvivors;

    public string StrayBannerText =>
        "Strays survived a reap and are still running: "
        + string.Join("; ", _supervisor.StraySurvivorDetails)
        + ". New runners are refused until you acknowledge this.";

    public void Reload()
    {
        ForgeConfig config = _configAccessor();

        foreach (RunnerCard card in Cards)
        {
            RunnerConfig? runnerConfig = config.Runners.FirstOrDefault(r => r.ClassId == card.ClassId);
            if (runnerConfig is null) continue;
            card.Enabled = runnerConfig.Enabled;
            card.Replicas = runnerConfig.Replicas;

            // macOS classes run on the Mac; this app cannot start them, and
            // saying so is better than a card that silently does nothing.
            if (!card.Class.RunsOnWindows)
            {
                card.BlockedReason = "runs on the Mac host";
            }
        }

        LastProof = config.Verification.LastProof;
    }

    public void ApplyPreflightBlocks(IReadOnlyDictionary<string, string> blocked)
    {
        foreach (RunnerCard card in Cards)
        {
            if (!card.Class.RunsOnWindows) continue;
            card.BlockedReason = blocked.TryGetValue(card.ClassId, out string? reason) ? reason : "";
        }
    }

    public void PersistToConfig()
    {
        ForgeConfig config = _configAccessor();
        foreach (RunnerCard card in Cards)
        {
            RunnerConfig? runnerConfig = config.Runners.FirstOrDefault(r => r.ClassId == card.ClassId);
            if (runnerConfig is null) continue;
            runnerConfig.Enabled = card.Enabled;
            runnerConfig.Replicas = card.Replicas;
        }
        _saveConfig();
    }

    private void OnSupervisorStatusChanged()
    {
        foreach (RunnerCard card in Cards)
        {
            card.Replicas_.Clear();
            foreach (ReplicaStatus replica in _supervisor.Replicas.Where(r => r.ClassId == card.ClassId))
            {
                card.Replicas_.Add(replica);
            }
        }

        OnPropertyChanged(nameof(StrayBannerVisible));
        OnPropertyChanged(nameof(StrayBannerText));
    }

    private async Task StartAsync(RunnerCard? card)
    {
        if (card is null || !card.IsAvailable) return;
        PersistToConfig();

        // Refuse early, and say what is missing. Without this the start goes
        // ahead, fails minting a JIT config, and reports a GitHub API error that
        // never mentions the empty App ID that actually caused it.
        IReadOnlyList<ConfigStore.SetupGap> gaps = ConfigStore.DescribeSetupGaps(_configAccessor());
        if (gaps.Count > 0)
        {
            SetupWarning =
                "Cannot start: " + string.Join(", ", gaps.Select(g => g.What))
                + $". Fill these in on the {string.Join(" and ", gaps.Select(g => g.Page).Distinct())} page.";
            return;
        }

        SetupWarning = "";
        await _supervisor.StartClassAsync(_configAccessor(), card.Class).ConfigureAwait(true);
    }

    private string _setupWarning = "";

    /// <summary>Why a start was refused, in the words of the fields that are missing.</summary>
    public string SetupWarning
    {
        get => _setupWarning;
        private set { SetProperty(ref _setupWarning, value); OnPropertyChanged(nameof(HasSetupWarning)); }
    }

    public bool HasSetupWarning => _setupWarning.Length > 0;

    private async Task StopAsync(RunnerCard? card)
    {
        if (card is null) return;
        await _supervisor.StopClassAsync(card.Class).ConfigureAwait(true);
    }

    private async Task RunSelfTestAsync()
    {
        var progress = new Progress<SelfTestProgress>(p => SelfTestStatus = $"{p.Stage}: {p.Detail}");

        SelfTestResult result = await _selfTestService
            .RunAsync(_configAccessor(), progress).ConfigureAwait(true);

        LastProof = result;
        SelfTestStatus = result.Passed
            ? $"Self-test PASSED in {result.DurationSeconds}s."
            : $"Self-test FAILED: {result.Conclusion}.";
    }
}
