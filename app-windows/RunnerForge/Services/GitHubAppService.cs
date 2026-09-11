using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using RunnerForge.Models;

namespace RunnerForge.Services;

/// <summary>
/// Turns a GitHub App private key into short-lived credentials, and mints the
/// single-use JIT config every runner registers with.
/// </summary>
/// <remarks>
/// There is no long-lived registration token anywhere in this product, and no
/// <c>config.cmd</c> step: a JIT config IS the configuration, valid for exactly
/// one job.
/// </remarks>
public sealed class GitHubAppService(LogBus logBus, SecretStore secretStore, HttpClient httpClient)
{
    private readonly LogBus _logBus = logBus;
    private readonly SecretStore _secretStore = secretStore;
    private readonly HttpClient _httpClient = httpClient;

    private string? _cachedToken;
    private DateTimeOffset _cachedTokenExpiry = DateTimeOffset.MinValue;

    public string ApiBaseUrl { get; set; } = "https://api.github.com";

    /// <summary>
    /// Signs an app JWT. <c>iat</c> is backdated 60 seconds to absorb clock skew,
    /// which GitHub otherwise rejects as a token issued in the future, and
    /// <c>exp</c> is 9 minutes, inside GitHub's 10-minute maximum.
    /// </summary>
    public string CreateAppJwt(string appId, string privateKeyPem)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(appId);
        ArgumentException.ThrowIfNullOrWhiteSpace(privateKeyPem);

        if (!privateKeyPem.Contains("PRIVATE KEY", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The stored GitHub App key is not a PEM private key. Re-enter it on the Credentials page.");
        }

        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        string header = """{"alg":"RS256","typ":"JWT"}""";
        string payload = $$"""{"iat":{{now - 60}},"exp":{{now + 540}},"iss":"{{appId}}"}""";

        string signingInput = Base64Url(Encoding.UTF8.GetBytes(header))
                              + "." + Base64Url(Encoding.UTF8.GetBytes(payload));

        using var rsa = RSA.Create();
        rsa.ImportFromPem(privateKeyPem);

        byte[] signature = rsa.SignData(
            Encoding.UTF8.GetBytes(signingInput), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);

        return signingInput + "." + Base64Url(signature);
    }

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>
    /// An installation access token, cached for 50 minutes. GitHub issues them
    /// for 60; the margin means a token never expires mid-use.
    /// </summary>
    public async Task<string> GetInstallationTokenAsync(
        ForgeConfig config, CancellationToken cancellationToken = default)
    {
        if (_cachedToken is not null && DateTimeOffset.UtcNow < _cachedTokenExpiry)
        {
            return _cachedToken;
        }

        string privateKey = _secretStore.Read("githubAppPrivateKey")
            ?? throw new InvalidOperationException(
                "No GitHub App private key is stored. Add it on the Credentials page; "
                + "it is kept in Windows Credential Manager, never in forge.json.");

        string jwt = CreateAppJwt(config.GitHub.AppId, privateKey);

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            $"{ApiBaseUrl}/app/installations/{config.GitHub.InstallationId}/access_tokens");
        ApplyHeaders(request, "Bearer", jwt);

        using HttpResponseMessage response =
            await SendWithRetryAsync(request, cancellationToken).ConfigureAwait(false);
        string body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            // GitHub's own message, verbatim. Guessing what a 401 means wastes
            // far more time than reading what GitHub actually said.
            throw new InvalidOperationException(
                $"Could not mint an installation token ({(int)response.StatusCode}). GitHub said:{Environment.NewLine}{body}");
        }

        JsonNode node = JsonNode.Parse(body)
            ?? throw new InvalidOperationException("The token response was not JSON.");
        string token = node["token"]?.GetValue<string>()
            ?? throw new InvalidOperationException("The token response contained no token.");

        _logBus.RegisterSecret(token);
        _cachedToken = token;
        _cachedTokenExpiry = DateTimeOffset.UtcNow.AddMinutes(50);
        _logBus.Info("github", "minted an installation token (cached 50 minutes)");

        return token;
    }

    /// <summary>
    /// Mints a JIT config for one runner. The returned blob is the runner's whole
    /// configuration and is valid for exactly one job.
    /// </summary>
    public async Task<JitConfig> GenerateJitConfigAsync(
        ForgeConfig config,
        string repo,
        RunnerClass runnerClass,
        CancellationToken cancellationToken = default)
    {
        string token = await GetInstallationTokenAsync(config, cancellationToken).ConfigureAwait(false);

        string shortHost = new string(Environment.MachineName
            .Where(char.IsLetterOrDigit).Take(16).ToArray()).ToLowerInvariant();
        string suffix = Convert.ToHexString(RandomNumberGenerator.GetBytes(4)).ToLowerInvariant();
        string runnerName = $"forge-{runnerClass.ClassId}-{shortHost}-{suffix}";

        RunnerConfig? configured = config.Runners.FirstOrDefault(r => r.ClassId == runnerClass.ClassId);
        IReadOnlyList<string> labels = configured?.Labels is { Count: > 0 }
            ? configured.Labels : runnerClass.Labels;

        var payload = new JsonObject
        {
            ["name"] = runnerName,
            ["runner_group_id"] = 1,
            ["labels"] = new JsonArray([.. labels.Select(l => (JsonNode)JsonValue.Create(l)!)]),
        };

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            $"{ApiBaseUrl}/repos/{config.GitHub.Owner}/{repo}/actions/runners/generate-jitconfig")
        {
            Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        ApplyHeaders(request, "Bearer", token);

        using HttpResponseMessage response =
            await SendWithRetryAsync(request, cancellationToken).ConfigureAwait(false);
        string body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"Could not generate a JIT config ({(int)response.StatusCode}). GitHub said:{Environment.NewLine}{body}");
        }

        JsonNode node = JsonNode.Parse(body)
            ?? throw new InvalidOperationException("The JIT config response was not JSON.");
        string blob = node["encoded_jit_config"]?.GetValue<string>()
            ?? throw new InvalidOperationException("The response contained no encoded_jit_config.");

        _logBus.RegisterSecret(blob);
        // The LENGTH only. The value must never reach a log.
        _logBus.Info("github", $"minted a JIT config for {runnerName} ({blob.Length} bytes)");

        return new JitConfig(runnerName, blob);
    }

    /// <summary>Verifies the App key by asking GitHub who we are.</summary>
    public async Task<string> TestAppCredentialsAsync(
        ForgeConfig config, CancellationToken cancellationToken = default)
    {
        string privateKey = _secretStore.Read("githubAppPrivateKey")
            ?? throw new InvalidOperationException("No GitHub App private key is stored.");

        string jwt = CreateAppJwt(config.GitHub.AppId, privateKey);

        using var request = new HttpRequestMessage(HttpMethod.Get, $"{ApiBaseUrl}/app");
        ApplyHeaders(request, "Bearer", jwt);

        using HttpResponseMessage response =
            await SendWithRetryAsync(request, cancellationToken).ConfigureAwait(false);
        string body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"GET /app failed ({(int)response.StatusCode}). GitHub said:{Environment.NewLine}{body}");
        }

        JsonNode? node = JsonNode.Parse(body);
        return node?["slug"]?.GetValue<string>() ?? "(the app has no slug)";
    }

    /// <summary>Checks repository access, reporting 200/404/403 distinctly.</summary>
    public async Task<string> VerifyRepositoryAccessAsync(
        ForgeConfig config, string repo, CancellationToken cancellationToken = default)
    {
        string token = await GetInstallationTokenAsync(config, cancellationToken).ConfigureAwait(false);

        using var request = new HttpRequestMessage(
            HttpMethod.Get, $"{ApiBaseUrl}/repos/{config.GitHub.Owner}/{repo}");
        ApplyHeaders(request, "Bearer", token);

        using HttpResponseMessage response =
            await SendWithRetryAsync(request, cancellationToken).ConfigureAwait(false);

        return (int)response.StatusCode switch
        {
            200 => "OK — the installation can see this repository.",
            404 => "404 — either the repository does not exist, or the App is not installed on it. "
                   + "GitHub returns 404 rather than 403 for repositories you cannot see at all.",
            403 => "403 — the App is installed but lacks permission. It needs Administration: read & write "
                   + "to register self-hosted runners.",
            _ => $"{(int)response.StatusCode} {response.ReasonPhrase}",
        };
    }

    private static void ApplyHeaders(HttpRequestMessage request, string scheme, string token)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue(scheme, token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        request.Headers.UserAgent.ParseAdd("RunnerForge/1.0");
    }

    /// <summary>
    /// Retries 5xx and secondary-rate-limit 403s with exponential backoff and
    /// honours Retry-After. Other statuses are returned as-is for the caller to
    /// surface verbatim.
    /// </summary>
    private async Task<HttpResponseMessage> SendWithRetryAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        const int maxAttempts = 4;

        for (int attempt = 1; ; attempt++)
        {
            using HttpRequestMessage attemptRequest = await CloneAsync(request).ConfigureAwait(false);
            HttpResponseMessage response =
                await _httpClient.SendAsync(attemptRequest, cancellationToken).ConfigureAwait(false);

            bool retryable = (int)response.StatusCode >= 500
                             || ((int)response.StatusCode == 403
                                 && response.Headers.RetryAfter is not null);

            if (!retryable || attempt >= maxAttempts) return response;

            TimeSpan delay = response.Headers.RetryAfter?.Delta
                             ?? TimeSpan.FromSeconds(Math.Pow(2, attempt));

            _logBus.Warning("github",
                $"{(int)response.StatusCode} from {request.RequestUri?.AbsolutePath}; "
                + $"retrying in {delay.TotalSeconds:0}s (attempt {attempt}/{maxAttempts})");

            response.Dispose();
            await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
        }
    }

    private static async Task<HttpRequestMessage> CloneAsync(HttpRequestMessage request)
    {
        var clone = new HttpRequestMessage(request.Method, request.RequestUri);

        if (request.Content is not null)
        {
            string body = await request.Content.ReadAsStringAsync().ConfigureAwait(false);
            clone.Content = new StringContent(body, Encoding.UTF8, "application/json");
        }

        foreach ((string key, IEnumerable<string> values) in request.Headers)
        {
            clone.Headers.TryAddWithoutValidation(key, values);
        }

        return clone;
    }
}

/// <summary>
/// A single-use runner registration. The blob never touches disk and never
/// appears in an argument list.
/// </summary>
public sealed record JitConfig(string RunnerName, string EncodedConfig);
