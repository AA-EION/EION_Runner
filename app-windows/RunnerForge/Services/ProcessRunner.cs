using System.Diagnostics;
using System.Text;

namespace RunnerForge.Services;

public sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError)
{
    public bool Succeeded => ExitCode == 0;

    /// <summary>Both streams, for error messages that should show everything.</summary>
    public string CombinedOutput =>
        string.Join(Environment.NewLine,
            new[] { StandardOutput, StandardError }.Where(s => !string.IsNullOrWhiteSpace(s)));
}

/// <summary>
/// Runs external processes and streams their output into the LogBus.
/// </summary>
/// <remarks>
/// Secrets are passed through <paramref name="environment"/> or standard input,
/// NEVER through arguments: an argument list is readable by any user on the
/// machine via the process list. There is deliberately no overload that takes a
/// secret as an argument.
/// </remarks>
public sealed class ProcessRunner(LogBus logBus)
{
    private readonly LogBus _logBus = logBus;

    public async Task<ProcessResult> RunAsync(
        string fileName,
        IEnumerable<string> arguments,
        string? workingDirectory = null,
        IReadOnlyDictionary<string, string>? environment = null,
        string? standardInput = null,
        string logSource = "process",
        bool streamOutput = true,
        CancellationToken cancellationToken = default)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = standardInput is not null,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = workingDirectory ?? Environment.CurrentDirectory,

            // Decode child output as UTF-8 rather than the console's OEM code
            // page. Without this, a localised Windows mangles every non-ASCII
            // character on its way into the log: a real run produced
            //     "found: Firma de c\u00a2digo"
            // for "Firma de c\u00f3digo", because CP850 was being read as if it
            // were the default encoding. A log that corrupts the message is
            // worse than one that omits it, since the reader cannot tell which
            // happened.
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
        };

        foreach (string argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        if (environment is not null)
        {
            foreach ((string key, string value) in environment)
            {
                startInfo.Environment[key] = value;
                // Anything injected as an environment variable is, by
                // definition, something we do not want echoed back at us.
                _logBus.RegisterSecret(value);
            }
        }

        // The argument list is logged, which is safe precisely because secrets
        // are never in it. Redaction still runs as a second line of defence.
        _logBus.Debug(logSource, $"$ {fileName} {string.Join(' ', startInfo.ArgumentList)}");

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            stdout.AppendLine(e.Data);
            if (streamOutput) _logBus.Info(logSource, e.Data);
        };

        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            stderr.AppendLine(e.Data);
            if (streamOutput) _logBus.Warning(logSource, e.Data);
        };

        try
        {
            process.Start();
        }
        catch (Exception ex)
        {
            _logBus.Error(logSource, $"could not start '{fileName}': {ex.Message}");
            return new ProcessResult(-1, "", ex.Message);
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        if (standardInput is not null)
        {
            // The JIT config arrives this way. It is written, flushed, and the
            // stream closed immediately; the value never touches a file.
            _logBus.RegisterSecret(standardInput);
            await process.StandardInput.WriteLineAsync(standardInput.AsMemory(), cancellationToken)
                                       .ConfigureAwait(false);
            await process.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
            process.StandardInput.Close();
        }

        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryKill(process, logSource);
            throw;
        }

        return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString());
    }

    private void TryKill(Process process, string logSource)
    {
        try
        {
            if (!process.HasExited)
            {
                _logBus.Warning(logSource, $"cancelled; killing pid {process.Id}");
                process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception ex)
        {
            _logBus.Warning(logSource, $"could not kill the process: {ex.Message}");
        }
    }

    /// <summary>True when the executable can be found on PATH.</summary>
    public static bool IsOnPath(string executable)
    {
        string? pathValue = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(pathValue)) return false;

        string[] extensions = OperatingSystem.IsWindows()
            ? (Environment.GetEnvironmentVariable("PATHEXT") ?? ".EXE;.CMD;.BAT").Split(';')
            : [""];

        foreach (string directory in pathValue.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(directory)) continue;
            foreach (string extension in extensions)
            {
                try
                {
                    if (File.Exists(Path.Combine(directory, executable + extension))) return true;
                }
                catch (ArgumentException)
                {
                    // A malformed PATH entry is not worth failing over.
                }
            }
        }

        return false;
    }
}
