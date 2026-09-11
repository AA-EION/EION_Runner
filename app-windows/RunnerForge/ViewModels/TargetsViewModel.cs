using System.Collections.ObjectModel;
using RunnerForge.Models;
using RunnerForge.Services;

namespace RunnerForge.ViewModels;

public sealed class RepoTarget(string name) : ObservableObject
{
    private string _accessResult = "not verified";

    public string Name { get; } = name;

    public string AccessResult
    {
        get => _accessResult;
        set => SetProperty(ref _accessResult, value);
    }
}

/// <summary>Backs the Targets page: which repositories these runners serve.</summary>
public sealed class TargetsViewModel : ObservableObject
{
    private readonly GitHubAppService _appService;
    private readonly Func<ForgeConfig> _configAccessor;
    private readonly Action _saveConfig;

    private string _owner = "";
    private string _newRepo = "";

    public TargetsViewModel(GitHubAppService appService, Func<ForgeConfig> configAccessor, Action saveConfig)
    {
        _appService = appService;
        _configAccessor = configAccessor;
        _saveConfig = saveConfig;

        AddRepoCommand = new RelayCommand(_ => AddRepo(), _ => !string.IsNullOrWhiteSpace(NewRepo));
        RemoveRepoCommand = new RelayCommand(parameter => RemoveRepo(parameter as RepoTarget));
        VerifyAccessCommand = new AsyncRelayCommand(_ => VerifyAccessAsync());

        Reload();
    }

    public ObservableCollection<RepoTarget> Repos { get; } = [];

    public RelayCommand AddRepoCommand { get; }
    public RelayCommand RemoveRepoCommand { get; }
    public AsyncRelayCommand VerifyAccessCommand { get; }

    public string Owner
    {
        get => _owner;
        set
        {
            if (!SetProperty(ref _owner, value)) return;
            _configAccessor().GitHub.Owner = value;
            _saveConfig();
        }
    }

    public string NewRepo
    {
        get => _newRepo;
        set { SetProperty(ref _newRepo, value); AddRepoCommand.RaiseCanExecuteChanged(); }
    }

    public void Reload()
    {
        ForgeConfig config = _configAccessor();
        _owner = config.GitHub.Owner;
        OnPropertyChanged(nameof(Owner));

        Repos.Clear();
        foreach (string repo in config.GitHub.Repos) Repos.Add(new RepoTarget(repo));
    }

    private void AddRepo()
    {
        string name = NewRepo.Trim();
        if (string.IsNullOrWhiteSpace(name)) return;
        if (Repos.Any(r => r.Name == name)) return;

        Repos.Add(new RepoTarget(name));
        _configAccessor().GitHub.Repos.Add(name);
        _saveConfig();
        NewRepo = "";
    }

    private void RemoveRepo(RepoTarget? target)
    {
        if (target is null) return;
        Repos.Remove(target);
        _configAccessor().GitHub.Repos.Remove(target.Name);
        _saveConfig();
    }

    private async Task VerifyAccessAsync()
    {
        ForgeConfig config = _configAccessor();

        foreach (RepoTarget target in Repos)
        {
            target.AccessResult = "checking…";
            try
            {
                // 200, 404 and 403 mean different things and get different
                // messages. GitHub returns 404 rather than 403 for repositories
                // you cannot see at all, which is the confusing case.
                target.AccessResult = await _appService
                    .VerifyRepositoryAccessAsync(config, target.Name).ConfigureAwait(true);
            }
            catch (Exception ex)
            {
                target.AccessResult = ex.Message;
            }
        }
    }
}
