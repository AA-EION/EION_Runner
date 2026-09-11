using System.Text.Json;
using System.Text.Json.Nodes;
using RunnerForge.Models;

namespace RunnerForge.Services;

/// <summary>Raised when forge.json does not satisfy the schema.</summary>
public sealed class ConfigValidationException(IReadOnlyList<string> problems)
    : Exception(BuildMessage(problems))
{
    public IReadOnlyList<string> Problems { get; } = problems;

    private static string BuildMessage(IReadOnlyList<string> problems) =>
        "forge.json is not valid:" + Environment.NewLine
        + string.Join(Environment.NewLine, problems.Select(p => "  " + p));
}

/// <summary>
/// Reads and writes forge.json, validating on load and reporting the offending
/// JSON pointer in readable text rather than a stack trace.
/// </summary>
public sealed class ConfigStore(LogBus logBus)
{
    private readonly LogBus _logBus = logBus;

    /// <summary>%ProgramData%\RunnerForge\forge.json</summary>
    public static string DefaultConfigPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "RunnerForge", "forge.json");

    public static string DefaultWorkDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "RunnerForge", "work");

    /// <summary>%LOCALAPPDATA%\RunnerForge\forge.json — the per-user fallback.</summary>
    public static string FallbackConfigPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "RunnerForge", "forge.json");

    public string ConfigPath { get; set; } = DefaultConfigPath;

    public ForgeConfig Load()
    {
        if (!File.Exists(ConfigPath))
        {
            _logBus.Info("config", $"no config at {ConfigPath}; creating defaults");
            ForgeConfig created = ForgeConfig.CreateDefault(DefaultWorkDir);

            // ---------------------------------------------------------------
            // The config is machine-wide BY DESIGN: runners are a property of
            // the machine, not of whoever happens to be logged in. But
            // %ProgramData%\RunnerForge can be unwritable for the person
            // running the app — created by an elevated run or another account,
            // locked down by policy — and on a standard desktop that is a
            // realistic, invisible failure.
            //
            // Refusing to start over it would be the wrong trade. FAILING TO
            // START IS WORSE THAN A PER-USER CONFIG, so fall back, say so
            // loudly in the log, and carry on. What must never happen is what
            // used to: the exception escaped Load(), escaped the service
            // container, and killed the process before any window or handler
            // existed — no UI and no error.
            // ---------------------------------------------------------------
            try
            {
                Save(created);
            }
            catch (Exception ex) when (ex is UnauthorizedAccessException or IOException)
            {
                _logBus.Warning("config",
                    $"cannot write {ConfigPath} ({ex.GetType().Name}: {ex.Message}); "
                    + $"falling back to the per-user config at {FallbackConfigPath}. "
                    + "Settings will apply to this user only.");

                ConfigPath = FallbackConfigPath;

                if (File.Exists(ConfigPath))
                {
                    return Parse(File.ReadAllText(ConfigPath));
                }

                Save(created);
            }

            return created;
        }

        string json = File.ReadAllText(ConfigPath);
        return Parse(json);
    }

    /// <summary>
    /// Parses and validates. Separate from <see cref="Load"/> so the validation
    /// rules are directly testable without touching the filesystem.
    /// </summary>
    public ForgeConfig Parse(string json)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(json);
        }
        catch (JsonException ex)
        {
            throw new ConfigValidationException([$"/ : the file is not valid JSON — {ex.Message}"]);
        }

        if (node is null)
        {
            throw new ConfigValidationException(["/ : the file is empty"]);
        }

        IReadOnlyList<string> problems = Validate(node);
        if (problems.Count > 0) throw new ConfigValidationException(problems);

        ForgeConfig config = node.Deserialize<ForgeConfig>(ForgeConfig.SerializerOptions)
                             ?? throw new ConfigValidationException(["/ : could not be deserialized"]);

        return config;
    }

    /// <summary>
    /// The validation rules that matter, each reported against its JSON pointer.
    /// </summary>
    /// <remarks>
    /// This mirrors config/forge.schema.json. It is a hand-written check rather
    /// than a schema library so the app carries no third-party dependency for
    /// something this small, and so the messages can say what to do about it.
    /// </remarks>
    /// <summary>
    /// One thing the user still has to enter before runners can start, and the
    /// page that lets them enter it.
    /// </summary>
    /// <param name="Page">The navigation entry that fixes it, by name.</param>
    /// <param name="What">The setting, in the words the GUI uses for it.</param>
    /// <param name="HowToFix">Where the value comes from, for someone who does not already know.</param>
    public sealed record SetupGap(string Page, string What, string HowToFix);

    /// <summary>
    /// What is still unconfigured. This is NOT validation and it NEVER blocks
    /// loading or starting the app.
    /// </summary>
    /// <remarks>
    /// This distinction is the whole point. A freshly created forge.json has an
    /// empty owner, appId, installationId and repos, because those are exactly
    /// the things the GUI collects. Treating them as validation errors meant the
    /// app wrote a default config on first run and then REFUSED TO LOAD THE FILE
    /// IT HAD JUST WRITTEN on the second — a bootstrap paradox that left no way
    /// in, since the only way to fill the fields is the window that would not
    /// open. Structural problems (a malformed file, a bad runner class, a secret
    /// stored in plaintext) still block, because those cannot be fixed by typing
    /// in a text box.
    /// </remarks>
    public static IReadOnlyList<SetupGap> DescribeSetupGaps(ForgeConfig config)
    {
        var gaps = new List<SetupGap>();

        if (string.IsNullOrWhiteSpace(config.GitHub.Owner))
        {
            gaps.Add(new SetupGap("Targets", "GitHub owner",
                "The user or organisation that owns the repositories — the first part of "
                + "github.com/OWNER/repo."));
        }

        if (config.GitHub.Repos.Count == 0)
        {
            gaps.Add(new SetupGap("Targets", "At least one repository",
                "The repositories these runners will accept jobs from."));
        }

        if (string.IsNullOrWhiteSpace(config.GitHub.AppId))
        {
            gaps.Add(new SetupGap("Credentials", "GitHub App ID",
                "On github.com, Settings → Developer settings → GitHub Apps → your App. "
                + "The App ID is shown at the top. It is not a secret."));
        }

        if (string.IsNullOrWhiteSpace(config.GitHub.InstallationId))
        {
            gaps.Add(new SetupGap("Credentials", "Installation ID",
                "Install the App on your account, then read the number at the end of the "
                + "browser address: .../settings/installations/INSTALLATION_ID. Not a secret."));
        }

        if (config.Runners.Count == 0)
        {
            gaps.Add(new SetupGap("Runners", "At least one runner class",
                "Choose which kinds of job this machine should accept."));
        }

        return gaps;
    }

    public static IReadOnlyList<string> Validate(JsonNode root)
    {
        var problems = new List<string>();

        if (root is not JsonObject obj)
        {
            return ["/ : the top level must be an object"];
        }

        int? schemaVersion = obj["schemaVersion"]?.GetValue<int>();
        if (schemaVersion != 1)
        {
            problems.Add($"/schemaVersion : must be 1, found {schemaVersion?.ToString() ?? "nothing"}");
        }

        // No secret may ever live in this file. Catching it here means a
        // mistake is reported rather than silently persisted.
        foreach (string forbidden in ForbiddenKeys)
        {
            if (FindKeyRecursive(obj, forbidden, out string pointer))
            {
                problems.Add($"{pointer} : '{forbidden}' is a SECRET and must never appear in forge.json. "
                             + "It belongs in Windows Credential Manager.");
            }
        }

        // NOTE: the emptiness of github/owner, appId, installationId and repos is
        // deliberately NOT checked here. Those four are what the GUI exists to
        // collect, and an unconfigured app is not a corrupt file. See
        // DescribeSetupGaps below.
        if (obj["github"] is not JsonObject)
        {
            problems.Add("/github : missing");
        }

        if (obj["runners"] is not JsonArray runners)
        {
            problems.Add("/runners : missing");
        }
        else
        {
            for (int i = 0; i < runners.Count; i++)
            {
                if (runners[i] is not JsonObject runner) { problems.Add($"/runners/{i} : must be an object"); continue; }

                string? classId = runner["classId"]?.GetValue<string>();
                RunnerClass? runnerClass = RunnerClass.All.FirstOrDefault(c => c.ClassId == classId);
                if (runnerClass is null)
                {
                    problems.Add($"/runners/{i}/classId : '{classId}' is not one of "
                                 + string.Join(", ", RunnerClass.All.Select(c => c.ClassId)));
                    continue;
                }

                int replicas = runner["replicas"]?.GetValue<int>() ?? runnerClass.DefaultReplicas;
                if (replicas < runnerClass.MinReplicas || replicas > runnerClass.MaxReplicas)
                {
                    problems.Add($"/runners/{i}/replicas : {replicas} is outside "
                                 + $"{runnerClass.MinReplicas}..{runnerClass.MaxReplicas} for {runnerClass.ClassId}"
                                 + (runnerClass.ReplicasAreFixed
                                    ? " — an iLok class is fixed at 1 because there is one dongle"
                                    : ""));
                }

                int timeout = runner["jobTimeoutMinutes"]?.GetValue<int>() ?? 60;
                if (timeout is < 1 or > 720)
                    problems.Add($"/runners/{i}/jobTimeoutMinutes : {timeout} is outside 1..720");
            }
        }

        if (obj["signing"] is not JsonObject signing)
        {
            problems.Add("/signing : missing");
        }
        else
        {
            string? mode = signing["mode"]?.GetValue<string>();
            if (mode is not ("cloud" or "windows-ilok" or "macos-ilok"))
                problems.Add($"/signing/mode : '{mode}' is not one of cloud, windows-ilok, macos-ilok");

            if (signing["windows"] is JsonObject windows)
            {
                string? provider = windows["provider"]?.GetValue<string>();
                if (provider is not ("none" or "azure-trusted-signing"))
                    problems.Add($"/signing/windows/provider : '{provider}' is not one of none, azure-trusted-signing");
            }
        }

        if (obj["retention"] is JsonObject retention)
        {
            if (retention["keepBaseImages"]?.GetValue<bool>() == false)
                problems.Add("/retention/keepBaseImages : must be true — rebuilding base images costs tens of minutes");
            if (retention["keepTartImages"]?.GetValue<bool>() == false)
                problems.Add("/retention/keepTartImages : must be true — only per-job clones are ever deleted");

            int days = retention["logRetentionDays"]?.GetValue<int>() ?? 7;
            if (days is < 1 or > 365)
                problems.Add($"/retention/logRetentionDays : {days} is outside 1..365");
        }

        if (obj["limits"] is JsonObject limits)
        {
            int gb = limits["maxDiskGb"]?.GetValue<int>() ?? 120;
            if (gb is < 20 or > 4096)
                problems.Add($"/limits/maxDiskGb : {gb} is outside 20..4096");
        }

        if (obj["telemetry"]?.GetValue<bool>() == true)
        {
            problems.Add("/telemetry : must be false — Runner Forge sends no telemetry");
        }

        if (obj["paths"] is JsonObject paths
            && string.IsNullOrWhiteSpace(paths["workDir"]?.GetValue<string>()))
        {
            problems.Add("/paths/workDir : must not be empty");
        }

        return problems;
    }

    /// <summary>Keystore key names. None of these may appear anywhere in forge.json.</summary>
    public static IReadOnlyList<string> ForbiddenKeys { get; } =
    [
        "githubAppPrivateKey", "pacePassword", "azureClientId", "azureClientSecret",
        "azureTenantId", "appleDevIdP12", "appleDevIdP12Password",
        "appleAscIssuerId", "appleAscKeyId", "appleAscPrivateKey",
    ];

    private static bool FindKeyRecursive(JsonNode node, string key, out string pointer)
    {
        pointer = "";
        switch (node)
        {
            case JsonObject obj:
                foreach ((string name, JsonNode? child) in obj)
                {
                    if (name == key) { pointer = "/" + name; return true; }
                    if (child is not null && FindKeyRecursive(child, key, out string nested))
                    {
                        pointer = "/" + name + nested;
                        return true;
                    }
                }
                return false;

            case JsonArray array:
                for (int i = 0; i < array.Count; i++)
                {
                    if (array[i] is { } element && FindKeyRecursive(element, key, out string nested))
                    {
                        pointer = $"/{i}{nested}";
                        return true;
                    }
                }
                return false;

            default:
                return false;
        }
    }

    public void Save(ForgeConfig config)
    {
        string? directory = Path.GetDirectoryName(ConfigPath);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

        string json = JsonSerializer.Serialize(config, ForgeConfig.SerializerOptions);

        // Write to a temp file and move into place, so a crash mid-write cannot
        // leave a truncated config that the next launch refuses to load.
        string temporary = ConfigPath + ".tmp";
        File.WriteAllText(temporary, json);
        File.Move(temporary, ConfigPath, overwrite: true);

        _logBus.Info("config", $"saved {ConfigPath}");
    }

    public string Serialize(ForgeConfig config) =>
        JsonSerializer.Serialize(config, ForgeConfig.SerializerOptions);
}
