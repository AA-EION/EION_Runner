using System.IO.Compression;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using RunnerForge.Models;

namespace RunnerForge.Services;

public sealed record WorkflowArtifact(long Id, string Name, long SizeInBytes, bool Expired, string ArchiveDownloadUrl);

public sealed record WorkflowJobInfo(string Name, string Status, string? Conclusion, string? RunnerName);

public sealed record WorkflowRunInfo(long Id, string Name, string Status, string? Conclusion, DateTimeOffset StartedAt);

/// <summary>
/// Dispatches workflows, waits for them, and pulls their artifacts back down.
/// This is what makes the in-app self-test possible.
/// </summary>
public sealed class GitHubActionsService(LogBus logBus, GitHubAppService appService, HttpClient httpClient)
{
    private readonly LogBus _logBus = logBus;
    private readonly GitHubAppService _appService = appService;
    private readonly HttpClient _httpClient = httpClient;

    public string ApiBaseUrl { get; set; } = "https://api.github.com";

    public TimeSpan PollInterval { get; set; } = TimeSpan.FromSeconds(15);

    /// <summary>
    /// Dispatches a workflow and resolves the run it created.
    /// </summary>
    /// <remarks>
    /// The run is found by matching a unique tag echoed into the workflow's
    /// <c>run-name</c>. Taking "the newest run" is race-prone and simply wrong
    /// under concurrency: two dispatches seconds apart would both resolve to
    /// whichever appeared first.
    /// </remarks>
    public async Task<long> DispatchWorkflowAsync(
        ForgeConfig config,
        string repo,
        string workflowFile,
        string gitRef,
        IReadOnlyDictionary<string, string> inputs,
        CancellationToken cancellationToken = default)
    {
        if (!inputs.TryGetValue("run_name_tag", out string? tag) || string.IsNullOrWhiteSpace(tag))
        {
            throw new ArgumentException(
                "inputs must contain a unique 'run_name_tag'. Without it the dispatched run cannot be "
                + "identified reliably, and resolving 'the newest run' is wrong under concurrency.",
                nameof(inputs));
        }

        var inputsNode = new JsonObject();
        foreach ((string key, string value) in inputs) inputsNode[key] = value;

        var payload = new JsonObject { ["ref"] = gitRef, ["inputs"] = inputsNode };

        string token = await _appService.GetInstallationTokenAsync(config, cancellationToken).ConfigureAwait(false);

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            $"{ApiBaseUrl}/repos/{config.GitHub.Owner}/{repo}/actions/workflows/{workflowFile}/dispatches")
        {
            Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        ApplyHeaders(request, token);

        using HttpResponseMessage response =
            await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            string body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            throw new InvalidOperationException(
                $"Dispatch failed ({(int)response.StatusCode}). GitHub said:{Environment.NewLine}{body}");
        }

        _logBus.Info("actions", $"dispatched {workflowFile} on {gitRef} with tag {tag}");

        // GitHub takes a moment to index the new run.
        for (int attempt = 1; attempt <= 30; attempt++)
        {
            JsonNode runs = await GetJsonAsync(config,
                $"/repos/{config.GitHub.Owner}/{repo}/actions/runs?event=workflow_dispatch&per_page=30",
                cancellationToken).ConfigureAwait(false);

            foreach (JsonNode? run in runs["workflow_runs"]?.AsArray() ?? [])
            {
                string? name = run?["name"]?.GetValue<string>();
                if (name is not null && name.Contains(tag, StringComparison.Ordinal))
                {
                    long id = run!["id"]!.GetValue<long>();
                    _logBus.Info("actions", $"resolved the dispatched run by its tag: {id}");
                    return id;
                }
            }

            await Task.Delay(TimeSpan.FromSeconds(4), cancellationToken).ConfigureAwait(false);
        }

        throw new InvalidOperationException(
            $"The workflow was dispatched but no run carrying the tag '{tag}' appeared within two minutes. "
            + "Check that the workflow echoes run_name_tag into its run-name.");
    }

    /// <summary>
    /// Polls until the run completes, logging each status transition. Returns
    /// success, failure, cancelled or timed_out.
    /// </summary>
    public async Task<string> WaitForRunAsync(
        ForgeConfig config,
        string repo,
        long runId,
        TimeSpan timeout,
        IProgress<string>? progress = null,
        CancellationToken cancellationToken = default)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow + timeout;
        string lastStatus = "";

        while (DateTimeOffset.UtcNow < deadline)
        {
            JsonNode run = await GetJsonAsync(config,
                $"/repos/{config.GitHub.Owner}/{repo}/actions/runs/{runId}", cancellationToken)
                .ConfigureAwait(false);

            string status = run["status"]?.GetValue<string>() ?? "unknown";
            string? conclusion = run["conclusion"]?.GetValue<string>();

            if (status != lastStatus)
            {
                _logBus.Info("actions", $"run {runId}: {status}");
                progress?.Report($"run {runId}: {status}");
                lastStatus = status;
            }

            if (status == "completed")
            {
                _logBus.Info("actions", $"run {runId} concluded: {conclusion}");
                return conclusion ?? "failure";
            }

            await Task.Delay(PollInterval, cancellationToken).ConfigureAwait(false);
        }

        _logBus.Error("actions", $"run {runId} did not finish within {timeout.TotalMinutes:0} minutes");
        return "timed_out";
    }

    public async Task<IReadOnlyList<WorkflowJobInfo>> ListJobsAsync(
        ForgeConfig config, string repo, long runId, CancellationToken cancellationToken = default)
    {
        JsonNode node = await GetJsonAsync(config,
            $"/repos/{config.GitHub.Owner}/{repo}/actions/runs/{runId}/jobs?per_page=100",
            cancellationToken).ConfigureAwait(false);

        var jobs = new List<WorkflowJobInfo>();
        foreach (JsonNode? job in node["jobs"]?.AsArray() ?? [])
        {
            if (job is null) continue;
            jobs.Add(new WorkflowJobInfo(
                job["name"]?.GetValue<string>() ?? "",
                job["status"]?.GetValue<string>() ?? "",
                job["conclusion"]?.GetValue<string>(),
                job["runner_name"]?.GetValue<string>()));
        }

        return jobs;
    }

    public async Task<IReadOnlyList<WorkflowArtifact>> ListArtifactsAsync(
        ForgeConfig config, string repo, long runId, CancellationToken cancellationToken = default)
    {
        JsonNode node = await GetJsonAsync(config,
            $"/repos/{config.GitHub.Owner}/{repo}/actions/runs/{runId}/artifacts?per_page=100",
            cancellationToken).ConfigureAwait(false);

        var artifacts = new List<WorkflowArtifact>();
        foreach (JsonNode? artifact in node["artifacts"]?.AsArray() ?? [])
        {
            if (artifact is null) continue;
            artifacts.Add(new WorkflowArtifact(
                artifact["id"]!.GetValue<long>(),
                artifact["name"]?.GetValue<string>() ?? "",
                artifact["size_in_bytes"]?.GetValue<long>() ?? 0,
                artifact["expired"]?.GetValue<bool>() ?? false,
                artifact["archive_download_url"]?.GetValue<string>() ?? ""));
        }

        return artifacts;
    }

    /// <summary>Downloads an artifact, unzips it, and returns the extracted files.</summary>
    public async Task<IReadOnlyList<string>> DownloadArtifactAsync(
        ForgeConfig config,
        string repo,
        WorkflowArtifact artifact,
        string destinationDirectory,
        CancellationToken cancellationToken = default)
    {
        string token = await _appService.GetInstallationTokenAsync(config, cancellationToken).ConfigureAwait(false);

        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            $"{ApiBaseUrl}/repos/{config.GitHub.Owner}/{repo}/actions/artifacts/{artifact.Id}/zip");
        ApplyHeaders(request, token);

        using HttpResponseMessage response = await _httpClient
            .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"Downloading artifact '{artifact.Name}' failed ({(int)response.StatusCode}).");
        }

        Directory.CreateDirectory(destinationDirectory);
        string extractTo = Path.Combine(destinationDirectory, artifact.Name);
        Directory.CreateDirectory(extractTo);

        string zipPath = Path.Combine(destinationDirectory, artifact.Name + ".zip");
        await using (FileStream file = File.Create(zipPath))
        {
            await response.Content.CopyToAsync(file, cancellationToken).ConfigureAwait(false);
        }

        ZipFile.ExtractToDirectory(zipPath, extractTo, overwriteFiles: true);
        File.Delete(zipPath);

        string[] files = Directory.GetFiles(extractTo, "*", SearchOption.AllDirectories);
        _logBus.Info("actions", $"downloaded {artifact.Name}: {files.Length} file(s), {artifact.SizeInBytes} bytes");
        return files;
    }

    /// <summary>Job logs, for showing a failure in the UI instead of a shrug.</summary>
    public async Task<string> GetJobLogsAsync(
        ForgeConfig config, string repo, long runId, string jobName,
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<WorkflowJobInfo> jobs =
            await ListJobsAsync(config, repo, runId, cancellationToken).ConfigureAwait(false);

        JsonNode node = await GetJsonAsync(config,
            $"/repos/{config.GitHub.Owner}/{repo}/actions/runs/{runId}/jobs?per_page=100",
            cancellationToken).ConfigureAwait(false);

        long? jobId = null;
        foreach (JsonNode? job in node["jobs"]?.AsArray() ?? [])
        {
            if (job?["name"]?.GetValue<string>() == jobName) { jobId = job["id"]!.GetValue<long>(); break; }
        }

        if (jobId is null)
        {
            return $"No job named '{jobName}' in run {runId}. Jobs present: "
                   + string.Join(", ", jobs.Select(j => j.Name));
        }

        string token = await _appService.GetInstallationTokenAsync(config, cancellationToken).ConfigureAwait(false);
        using var request = new HttpRequestMessage(
            HttpMethod.Get, $"{ApiBaseUrl}/repos/{config.GitHub.Owner}/{repo}/actions/jobs/{jobId}/logs");
        ApplyHeaders(request, token);

        using HttpResponseMessage response =
            await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
        return await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Self-hosted runners registered on the repository. Used by crash recovery.</summary>
    public async Task<IReadOnlyList<(long Id, string Name, string Status)>> ListSelfHostedRunnersAsync(
        ForgeConfig config, string repo, CancellationToken cancellationToken = default)
    {
        JsonNode node = await GetJsonAsync(config,
            $"/repos/{config.GitHub.Owner}/{repo}/actions/runners?per_page=100",
            cancellationToken).ConfigureAwait(false);

        var runners = new List<(long, string, string)>();
        foreach (JsonNode? runner in node["runners"]?.AsArray() ?? [])
        {
            if (runner is null) continue;
            runners.Add((
                runner["id"]!.GetValue<long>(),
                runner["name"]?.GetValue<string>() ?? "",
                runner["status"]?.GetValue<string>() ?? ""));
        }

        return runners;
    }

    /// <summary>Removes a dangling registration left behind by a crash.</summary>
    public async Task<bool> DeleteRunnerAsync(
        ForgeConfig config, string repo, long runnerId, CancellationToken cancellationToken = default)
    {
        string token = await _appService.GetInstallationTokenAsync(config, cancellationToken).ConfigureAwait(false);

        using var request = new HttpRequestMessage(
            HttpMethod.Delete, $"{ApiBaseUrl}/repos/{config.GitHub.Owner}/{repo}/actions/runners/{runnerId}");
        ApplyHeaders(request, token);

        using HttpResponseMessage response =
            await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);

        _logBus.Info("actions", response.IsSuccessStatusCode
            ? $"removed offline runner registration {runnerId}"
            : $"could not remove runner {runnerId}: {(int)response.StatusCode}");

        return response.IsSuccessStatusCode;
    }

    private async Task<JsonNode> GetJsonAsync(
        ForgeConfig config, string path, CancellationToken cancellationToken)
    {
        string token = await _appService.GetInstallationTokenAsync(config, cancellationToken).ConfigureAwait(false);

        using var request = new HttpRequestMessage(HttpMethod.Get, ApiBaseUrl + path);
        ApplyHeaders(request, token);

        using HttpResponseMessage response =
            await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
        string body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"GET {path} failed ({(int)response.StatusCode}). GitHub said:{Environment.NewLine}{body}");
        }

        return JsonNode.Parse(body) ?? throw new InvalidOperationException($"GET {path} returned no JSON.");
    }

    private static void ApplyHeaders(HttpRequestMessage request, string token)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        request.Headers.UserAgent.ParseAdd("RunnerForge/1.0");
    }
}
