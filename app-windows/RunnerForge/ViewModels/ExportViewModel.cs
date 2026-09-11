using RunnerForge.Models;
using RunnerForge.Services;

namespace RunnerForge.ViewModels;

/// <summary>
/// Backs the Export page: renders the workflow templates and the secrets
/// checklist from the current configuration.
/// </summary>
public sealed class ExportViewModel : ObservableObject
{
    private readonly TemplateRenderer _renderer;
    private readonly SecretStore _secretStore;
    private readonly Func<ForgeConfig> _configAccessor;
    private readonly Func<bool> _signingSatisfied;

    private string _projectName = "MyPlugin";
    private string _sourceDir = ".";
    private string _renderedBuildWorkflow = "";
    private string _renderedSignWorkflow = "";
    private string _renderedChecklist = "";
    private string _status = "";

    public ExportViewModel(
        TemplateRenderer renderer,
        SecretStore secretStore,
        Func<ForgeConfig> configAccessor,
        Func<bool> signingSatisfied)
    {
        _renderer = renderer;
        _secretStore = secretStore;
        _configAccessor = configAccessor;
        _signingSatisfied = signingSatisfied;

        RenderCommand = new RelayCommand(_ => Render(), _ => CanExport);
    }

    public RelayCommand RenderCommand { get; }

    /// <summary>
    /// Export is disabled while the selected signing mode has unmet requirements.
    /// Emitting a workflow that cannot sign would produce a red run on someone
    /// else's machine.
    /// </summary>
    public bool CanExport => _signingSatisfied();

    public string ProjectName
    {
        get => _projectName;
        set => SetProperty(ref _projectName, value);
    }

    public string SourceDir
    {
        get => _sourceDir;
        set => SetProperty(ref _sourceDir, value);
    }

    public string RenderedBuildWorkflow
    {
        get => _renderedBuildWorkflow;
        private set => SetProperty(ref _renderedBuildWorkflow, value);
    }

    public string RenderedSignWorkflow
    {
        get => _renderedSignWorkflow;
        private set => SetProperty(ref _renderedSignWorkflow, value);
    }

    public string RenderedChecklist
    {
        get => _renderedChecklist;
        private set => SetProperty(ref _renderedChecklist, value);
    }

    public string Status
    {
        get => _status;
        private set => SetProperty(ref _status, value);
    }

    /// <summary>Where the templates live, relative to the installed app.</summary>
    public string TemplatesDirectory { get; set; } =
        Path.Combine(AppContext.BaseDirectory, "templates");

    public void Render()
    {
        try
        {
            Dictionary<string, string> values = TemplateRenderer.BuildValues(
                _configAccessor(), ProjectName, SourceDir, _secretStore.Presence());

            RenderedBuildWorkflow = RenderFile("workflow-build.yml.tmpl", values);
            RenderedSignWorkflow = RenderFile("workflow-sign.yml.tmpl", values);
            RenderedChecklist = RenderFile("secrets-checklist.md.tmpl", values);

            Status = "Rendered. Paste the YAML into .github/workflows/ in your project.";
        }
        catch (TemplateRenderer.UnsubstitutedPlaceholderException ex)
        {
            // An unsubstituted placeholder means the rendered YAML would fail at
            // run time, so it is an error rather than something to paste anyway.
            Status = ex.Message;
        }
        catch (Exception ex)
        {
            Status = ex.Message;
        }
    }

    private string RenderFile(string templateFile, IReadOnlyDictionary<string, string> values)
    {
        string path = Path.Combine(TemplatesDirectory, templateFile);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"Template not found: {path}. The templates ship alongside the executable.");
        }

        return _renderer.Render(File.ReadAllText(path), values);
    }

    /// <summary>Writes the rendered output to a folder the user picked.</summary>
    public void WriteTo(string directory)
    {
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "workflow-build.yml"), RenderedBuildWorkflow);
        File.WriteAllText(Path.Combine(directory, "workflow-sign.yml"), RenderedSignWorkflow);
        File.WriteAllText(Path.Combine(directory, "secrets-checklist.md"), RenderedChecklist);
        Status = $"Written to {directory}";
    }
}
