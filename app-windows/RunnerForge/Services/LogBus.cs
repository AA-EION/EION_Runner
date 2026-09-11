using System.Collections.Concurrent;
using System.Text.RegularExpressions;

namespace RunnerForge.Services;

public enum LogLevel { Debug, Info, Warning, Error }

public sealed record LogEntry(DateTimeOffset Timestamp, LogLevel Level, string Source, string Message)
{
    public override string ToString() =>
        $"{Timestamp:HH:mm:ss} [{Level,-7}] {Source,-14} {Message}";
}

/// <summary>
/// The single place every log line passes through, so redaction cannot be
/// bypassed by forgetting to call it.
/// </summary>
/// <remarks>
/// EVERY line is redacted before it reaches the UI, a file, or the clipboard.
/// Secrets are registered here when they are read from the keystore, and any
/// occurrence of a registered value is replaced with <c>***</c>. That is
/// deliberately a value-based match rather than a pattern-based one: patterns
/// miss things, and a secret that reaches a log has already leaked.
/// </remarks>
public sealed class LogBus
{
    private readonly ConcurrentQueue<LogEntry> _entries = new();
    private readonly List<string> _secretValues = [];
    private readonly Lock _secretsLock = new();
    private const int MaxEntries = 20_000;

    /// <summary>Raised for each entry, already redacted.</summary>
    public event Action<LogEntry>? EntryAdded;

    /// <summary>
    /// Patterns for shapes that are secret regardless of whether we happen to
    /// hold the value — a PEM block, a bearer token, a base64 JIT config.
    /// Belt and braces behind the value-based redaction.
    /// </summary>
    private static readonly (Regex Pattern, string Replacement)[] ShapeRedactions =
    [
        (new Regex(@"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
                   RegexOptions.Singleline | RegexOptions.Compiled), "***PRIVATE KEY REDACTED***"),
        (new Regex(@"(?i)\b(authorization:\s*(bearer|token)\s+)\S+", RegexOptions.Compiled), "$1***"),
        (new Regex(@"(?i)(--(?:password|token|jitconfig|client-secret)[= ])\S+", RegexOptions.Compiled), "$1***"),
        (new Regex(@"(?i)\b(ghp_|gho_|ghs_|github_pat_)[A-Za-z0-9_]{20,}", RegexOptions.Compiled), "***"),
    ];

    /// <summary>
    /// Registers a secret value so it is scrubbed from every subsequent line.
    /// Call this the moment a secret is read from the keystore.
    /// </summary>
    public void RegisterSecret(string? value)
    {
        // Very short values would match far too much and turn logs into noise.
        if (string.IsNullOrWhiteSpace(value) || value.Length < 8) return;

        lock (_secretsLock)
        {
            if (!_secretValues.Contains(value)) _secretValues.Add(value);
        }
    }

    public void ForgetSecrets()
    {
        lock (_secretsLock) _secretValues.Clear();
    }

    public string Redact(string message)
    {
        if (string.IsNullOrEmpty(message)) return message;

        string result = message;

        lock (_secretsLock)
        {
            foreach (string secret in _secretValues)
            {
                result = result.Replace(secret, "***", StringComparison.Ordinal);
            }
        }

        foreach ((Regex pattern, string replacement) in ShapeRedactions)
        {
            result = pattern.Replace(result, replacement);
        }

        return result;
    }

    public void Write(LogLevel level, string source, string message)
    {
        var entry = new LogEntry(DateTimeOffset.Now, level, source, Redact(message));
        _entries.Enqueue(entry);

        while (_entries.Count > MaxEntries && _entries.TryDequeue(out _)) { }

        EntryAdded?.Invoke(entry);
    }

    public void Debug(string source, string message) => Write(LogLevel.Debug, source, message);
    public void Info(string source, string message) => Write(LogLevel.Info, source, message);
    public void Warning(string source, string message) => Write(LogLevel.Warning, source, message);
    public void Error(string source, string message) => Write(LogLevel.Error, source, message);

    public IReadOnlyList<LogEntry> Snapshot() => [.. _entries];

    public void Clear()
    {
        while (_entries.TryDequeue(out _)) { }
    }

    /// <summary>Already-redacted text, safe to write to a file or the clipboard.</summary>
    public string ToPlainText() => string.Join(Environment.NewLine, _entries.Select(e => e.ToString()));
}
