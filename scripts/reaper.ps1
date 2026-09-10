<#
.SYNOPSIS
    "Verify nothing keeps running" — the Windows Reaper.

.DESCRIPTION
    The Windows twin of scripts/reaper.sh, with identical semantics and identical
    exit codes.

    It answers exactly one question: is anything still alive that should not be?
    It runs on container exit, on job completion, on app close, and on a
    30-second watchdog poll.

    It does NOT decide what to delete — that is the Sweeper's job. Keeping the
    two apart matters: "is it running?" and "can I delete it?" have different
    answers and different blast radii.

    Exit codes are part of the contract and the GUI depends on them:
      0   clean            nothing stray was found
      10  strays killed    strays were found and are now gone
      20  strays survived  something ignored Kill(); the GUI shows a red banner
                           and refuses to start new runners until acknowledged
      2   usage error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $WorkDir,
    [Parameter(Mandatory = $false)] [string] $Scope,
    [Parameter(Mandatory = $false)] [switch] $DryRun,
    [Parameter(Mandatory = $false)] [int]    $GraceSeconds = 10,
    [Parameter(Mandatory = $false)] [switch] $Quiet
)

$ErrorActionPreference = 'Continue'

function Write-Reap { param([string] $Message) if (-not $Quiet) { Write-Host "[reaper] $Message" } }
function Write-Warn { param([string] $Message) Write-Host "[reaper] $Message" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Processes that must not exist outside a live, registered job.
#
# A build toolchain still running after the job that spawned it has ended is
# holding file locks and burning CPU on a machine the user believes is idle.
# MSBuild and mspdbsrv in particular are notorious for outliving their job.
# ---------------------------------------------------------------------------
$strayProcessNames = @(
    'Runner.Listener',
    'Runner.Worker',
    'MSBuild',
    'cl',
    'link',
    'cmake',
    'ninja',
    'ISCC',
    'wraptool',
    'mspdbsrv',
    'vctip'
)

# ---------------------------------------------------------------------------
# PIDs that are legitimately alive, read from state.json. Without this the
# Reaper would happily kill the runner it exists to protect.
# ---------------------------------------------------------------------------
$livePids  = @()
$liveNames = @()

$statePath = if ($WorkDir) { Join-Path $WorkDir 'state.json' } else { $null }

if ($statePath -and (Test-Path $statePath)) {
    try {
        $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json
        foreach ($runner in @($state.runners)) {
            if ($null -ne $runner.pid)        { $livePids  += [int] $runner.pid }
            if ($null -ne $runner.runnerName) { $liveNames += [string] $runner.runnerName }
        }
        Write-Reap "state.json lists live runners: $($liveNames -join ', ')"
    }
    catch {
        Write-Warn "state.json could not be parsed ($($_.Exception.Message)); treating every matching process as stray"
    }
}
else {
    Write-Reap 'no state.json found; treating every matching process as stray'
}

$selfPid = $PID

# ---------------------------------------------------------------------------
# Find stray processes.
# ---------------------------------------------------------------------------
$strays = @()

foreach ($name in $strayProcessNames) {
    foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        if ($process.Id -eq $selfPid) { continue }
        if ($livePids -contains $process.Id) { continue }

        # The full command line is what makes a stray diagnosable rather than
        # just a number in a log.
        $commandLine = $null
        try {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction SilentlyContinue).CommandLine
        }
        catch { }
        if (-not $commandLine) { $commandLine = $process.ProcessName }

        # `dotnet.exe` is only stray when it is running out of the work
        # directory; the machine's own dotnet processes are none of our business.
        if ($name -eq 'dotnet' -and $WorkDir -and ($commandLine -notlike "*$WorkDir*")) { continue }

        if ($Scope -and ($commandLine -notlike "*$Scope*")) { continue }

        $strays += [pscustomobject]@{
            Process     = $process
            Id          = $process.Id
            Name        = $name
            CommandLine = $commandLine
        }
    }
}

# `dotnet.exe` under the work dir, checked separately so the work-dir filter is
# never skipped by accident.
if ($WorkDir) {
    foreach ($process in @(Get-Process -Name 'dotnet' -ErrorAction SilentlyContinue)) {
        if ($process.Id -eq $selfPid -or $livePids -contains $process.Id) { continue }
        $commandLine = $null
        try {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction SilentlyContinue).CommandLine
        }
        catch { }
        if (-not $commandLine -or $commandLine -notlike "*$WorkDir*") { continue }
        if ($Scope -and ($commandLine -notlike "*$Scope*")) { continue }
        $strays += [pscustomobject]@{
            Process = $process; Id = $process.Id; Name = 'dotnet'; CommandLine = $commandLine
        }
    }
}

# ---------------------------------------------------------------------------
# Containers still `running` whose job has ended, and orphaned volume mounts.
# ---------------------------------------------------------------------------
$strayContainers = @()

if (Get-Command docker -ErrorAction SilentlyContinue) {
    $running = @(& docker ps --filter 'status=running' --format '{{.ID}} {{.Names}}' 2>$null)
    foreach ($line in $running) {
        if (-not $line) { continue }
        $parts = $line -split '\s+', 2
        $containerName = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }
        # A container whose runner name is in state.json is doing its job.
        if ($liveNames | Where-Object { $containerName -like "*$_*" }) { continue }
        if ($containerName -notlike 'forge-*' -and $containerName -notlike '*runnerforge*') { continue }
        if ($Scope -and ($containerName -notlike "*$Scope*")) { continue }
        $strayContainers += $parts[0]
    }
}

$total = $strays.Count + $strayContainers.Count

if ($total -eq 0) {
    Write-Reap 'clean: no stray processes or containers'
    exit 0
}

Write-Reap "found $total stray item(s)"
foreach ($stray in $strays)          { Write-Reap "  process   $($stray.Name) pid=$($stray.Id) :: $($stray.CommandLine)" }
foreach ($container in $strayContainers) { Write-Reap "  container $container" }

if ($DryRun) {
    Write-Reap 'dry run: nothing was killed'
    exit 0
}

# ---------------------------------------------------------------------------
# CloseMainWindow, wait, Kill, re-verify.
#
# Never Kill() first: a runner given the chance to shut down cleanly
# unregisters itself from GitHub, while one killed outright leaves an offline
# registration behind for crash recovery to clean up.
# ---------------------------------------------------------------------------
foreach ($stray in $strays) {
    Write-Reap "CloseMainWindow -> $($stray.Id)"
    try { [void] $stray.Process.CloseMainWindow() } catch { }
}

if ($strays.Count -gt 0) {
    Write-Reap "waiting ${GraceSeconds}s for a clean exit"
    $waited = 0
    while ($waited -lt $GraceSeconds) {
        $stillRunning = $false
        foreach ($stray in $strays) {
            if (Get-Process -Id $stray.Id -ErrorAction SilentlyContinue) { $stillRunning = $true }
        }
        if (-not $stillRunning) { break }
        Start-Sleep -Seconds 1
        $waited++
    }

    foreach ($stray in $strays) {
        if (Get-Process -Id $stray.Id -ErrorAction SilentlyContinue) {
            Write-Reap "Kill -> $($stray.Id) (ignored CloseMainWindow for ${GraceSeconds}s)"
            try { $stray.Process.Kill() } catch { }
        }
    }
}

foreach ($container in $strayContainers) {
    Write-Reap "stopping stray container $container"
    & docker stop --timeout $GraceSeconds $container 2>$null | Out-Null
    & docker rm -f $container 2>$null | Out-Null
}

# ---------------------------------------------------------------------------
# Re-verify. Reporting "killed" without checking is how a stray survives a
# Reaper run and nobody notices.
# ---------------------------------------------------------------------------
Start-Sleep -Seconds 1
$survivors = @()

foreach ($stray in $strays) {
    if (Get-Process -Id $stray.Id -ErrorAction SilentlyContinue) { $survivors += "process pid=$($stray.Id) ($($stray.Name))" }
}
foreach ($container in $strayContainers) {
    $still = @(& docker ps --filter "id=$container" --filter 'status=running' --format '{{.ID}}' 2>$null)
    if ($still.Count -gt 0) { $survivors += "container $container" }
}

if ($survivors.Count -gt 0) {
    Write-Warn "STRAYS SURVIVED — $($survivors.Count) item(s) are still present after Kill:"
    foreach ($survivor in $survivors) { Write-Warn "  $survivor" }
    Write-Warn 'new runners must not be started until this is resolved.'
    exit 20
}

Write-Reap "all $total stray item(s) confirmed gone"
exit 10
