<#
.SYNOPSIS
    win-build container entrypoint.

.DESCRIPTION
    Contract, identical to the Linux image's entrypoint.sh:

      1. Read the JIT config from stdin, or from RUNNER_JITCONFIG when the
         caller used --env-file.
      2. Export the cache locations the build expects.
      3. Run the Actions runner for exactly ONE job.
      4. Exit with the runner's exit code, unchanged.

    There is NO config.cmd step. A JIT config is not something you configure
    from; it IS the configuration, and it is valid for a single job.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Entry { param([string] $Message) Write-Host "[entrypoint] $Message" }

function Stop-WithError {
    param([string] $Message)
    Write-Host "[entrypoint] error: $Message" -ForegroundColor Red
    exit 78
}

# ---------------------------------------------------------------------------
# 1. Obtain the JIT config.
#
# It crosses the host -> container boundary by stdin or by an --env-file that
# the supervisor overwrites with random bytes and deletes the moment the
# container reports started. It is NEVER a --build-arg (recorded in image
# history) and never on the host's `docker run` command line, where any user on
# the machine could read it out of the process list.
# ---------------------------------------------------------------------------
$jitConfig = $null

if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_JITCONFIG)) {
    $jitConfig = $env:RUNNER_JITCONFIG
    # Drop it from the environment immediately.
    $env:RUNNER_JITCONFIG = $null
    Remove-Item Env:\RUNNER_JITCONFIG -ErrorAction SilentlyContinue
    Write-Entry "JIT config received from the environment ($($jitConfig.Length) bytes)"
}
else {
    if (-not [Console]::IsInputRedirected) {
        Stop-WithError "no JIT config supplied and stdin is a terminal. Provide it on stdin or as RUNNER_JITCONFIG. This image never registers with a long-lived registration token and has no config.cmd step to fall back to."
    }
    $jitConfig = [Console]::In.ReadLine()
    if ($null -ne $jitConfig) { $jitConfig = $jitConfig.Trim() }
    Write-Entry "JIT config received on stdin ($(if ($jitConfig) { $jitConfig.Length } else { 0 }) bytes)"
}

if ([string]::IsNullOrWhiteSpace($jitConfig)) {
    Stop-WithError "no JIT config supplied. Provide it on stdin or as RUNNER_JITCONFIG. This image never registers with a long-lived registration token and has no config.cmd step to fall back to."
}

# Only ever report the length. The value itself must not reach a log, the
# console, or a file.
Write-Entry "JIT config length looks plausible: $($jitConfig.Length) bytes"

# ---------------------------------------------------------------------------
# 2. Cache locations.
#
# These point at the named volumes (forge-fetchcontent, forge-sccache) so JUCE
# is cloned once per machine rather than once per build, and so the compiler
# cache survives between jobs. They are KEEP items: the Sweeper never deletes
# them, because deleting them is precisely what makes the next build slow.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($env:FETCHCONTENT_BASE_DIR)) { $env:FETCHCONTENT_BASE_DIR = 'C:\cache\fetchcontent' }
if ([string]::IsNullOrWhiteSpace($env:SCCACHE_DIR))           { $env:SCCACHE_DIR           = 'C:\cache\sccache' }

New-Item -ItemType Directory -Force -Path $env:FETCHCONTENT_BASE_DIR, $env:SCCACHE_DIR | Out-Null

# sccache is only useful if the compiler actually routes through it.
$env:SCCACHE_IDLE_TIMEOUT = '0'

Write-Entry "FETCHCONTENT_BASE_DIR=$env:FETCHCONTENT_BASE_DIR"
Write-Entry "SCCACHE_DIR=$env:SCCACHE_DIR"

$runnerHome = if ([string]::IsNullOrWhiteSpace($env:RUNNER_HOME)) { 'C:\actions-runner' } else { $env:RUNNER_HOME }
Set-Location $runnerHome

# ---------------------------------------------------------------------------
# 3. Run exactly one job.
#
# run.cmd --jitconfig is the only interface the Actions runner offers, so the
# blob does appear in this process's argument list. That is inside the
# container, whose process list is not the host's and which is destroyed after a
# single job. The boundary that matters — the host process list — never sees it,
# which is what the stdin/env-file handoff above is for.
# ---------------------------------------------------------------------------
Write-Entry 'starting the runner for a single job'

& cmd.exe /c "run.cmd --jitconfig $jitConfig"
$runnerExit = $LASTEXITCODE

# Drop the blob from this process's memory as soon as it is no longer needed.
$jitConfig = $null
[System.GC]::Collect()

Write-Entry "runner exited with code $runnerExit"

# 4. The runner's exit code is the container's exit code. The supervisor uses it
#    to tell "job finished" from "this class is broken" (three non-zero exits in
#    five minutes stops the class).
exit $runnerExit
