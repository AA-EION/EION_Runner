<#
.SYNOPSIS
    "Clean on close, keep only what makes the next run fast" — the Windows Sweeper.

.DESCRIPTION
    The Windows twin of scripts/sweeper.sh, with identical policy.

    It works from two EXPLICIT lists, never a heuristic, because erring in either
    direction is a bug:

      deleting a KEEP item  -> the next build re-clones JUCE and re-pulls a
                               multi-gigabyte base image, for nothing
      keeping a PURGE item  -> the disk fills and the machine stops building

    The single most important rule in this file: `docker system prune -a` is
    NEVER used. It would delete the tagged base images, which is exactly what the
    KEEP list exists to prevent. Targeted prunes only.

    -ReportJson writes the KEEP/PURGE breakdown with per-item sizes, which is
    what the GUI's Cleanup page renders as its two columns.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string] $WorkDir,
    [Parameter(Mandatory = $false)] [int]    $LogRetentionDays = 7,
    [Parameter(Mandatory = $false)] [switch] $DryRun,
    [Parameter(Mandatory = $false)] [string] $ReportJson,
    [Parameter(Mandatory = $false)] [string] $VersionsToml,
    [Parameter(Mandatory = $false)] [switch] $Quiet
)

$ErrorActionPreference = 'Continue'

function Write-Sweep { param([string] $Message) if (-not $Quiet) { Write-Host "[sweeper] $Message" } }

# ---------------------------------------------------------------------------
# THE KEEP LIST. Nothing here is ever deleted, on close or on demand.
# ---------------------------------------------------------------------------
$keepVolumes = @('forge-fetchcontent', 'forge-sccache', 'forge-ccache', 'forge-aax-sdk')

# Image tags come from versions.toml so this list cannot drift from what the
# builds actually produce.
function Read-Pin {
    param([string] $Path, [string] $Section, [string] $Key)
    $inSection = $false
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $inSection = ($Matches[1] -eq $Section); continue }
        if (-not $inSection) { continue }
        if ($line -match '^\s*#') { continue }
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*`"([^`"]+)`"") { return $Matches[1] }
    }
    return $null
}

if (-not $VersionsToml) {
    foreach ($candidate in @(
        (Join-Path $PSScriptRoot '..\versions.toml'),
        (Join-Path (Get-Location) 'versions.toml'),
        (Join-Path $WorkDir 'versions.toml'))) {
        if (Test-Path $candidate) { $VersionsToml = (Resolve-Path $candidate).Path; break }
    }
}

$keepImageTags = @()
if ($VersionsToml -and (Test-Path $VersionsToml)) {
    $winTag    = Read-Pin -Path $VersionsToml -Section 'windows_image' -Key 'tag'
    $linuxTag  = Read-Pin -Path $VersionsToml -Section 'linux_image'   -Key 'tag'
    $winBase   = Read-Pin -Path $VersionsToml -Section 'windows_image' -Key 'base'
    $linuxBase = Read-Pin -Path $VersionsToml -Section 'linux_image'   -Key 'base'
    if ($winTag)    { $keepImageTags += "runnerforge/win-build:$winTag" }
    if ($linuxTag)  { $keepImageTags += "runnerforge/linux-util:$linuxTag" }
    if ($winBase)   { $keepImageTags += $winBase }
    if ($linuxBase) { $keepImageTags += $linuxBase }
    Write-Sweep "KEEP list read from $VersionsToml"
}
else {
    Write-Sweep 'warning: versions.toml not found; the KEEP list cannot be verified, so no image pruning will run'
}

function Get-DirectoryBytes {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return 0 }
    $sum = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [int64] $sum
}

$keepReport      = [System.Collections.Generic.List[object]]::new()
$purgeReport     = [System.Collections.Generic.List[object]]::new()
$reclaimableBytes = [int64] 0
$reclaimedBytes   = [int64] 0
$presentBefore   = @()

function Add-Keep  { param([string] $Item, [int64] $Bytes) $keepReport.Add([pscustomobject]@{ item = $Item; bytes = $Bytes }) }
function Add-Purge {
    param([string] $Item, [int64] $Bytes)
    $purgeReport.Add([pscustomobject]@{ item = $Item; bytes = $Bytes })
    $script:reclaimableBytes += $Bytes
}

$dockerAvailable = $false
if (Get-Command docker -ErrorAction SilentlyContinue) {
    & docker info 2>$null | Out-Null
    $dockerAvailable = ($LASTEXITCODE -eq 0)
}

Write-Sweep '==> surveying'

# --- KEEP -------------------------------------------------------------------
if ($dockerAvailable) {
    foreach ($volume in $keepVolumes) {
        $mountpoint = & docker volume inspect $volume --format '{{.Mountpoint}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $mountpoint) { Add-Keep "volume $volume" (Get-DirectoryBytes $mountpoint) }
    }
    foreach ($tag in $keepImageTags) {
        $size = & docker image inspect $tag --format '{{.Size}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $size) {
            Add-Keep "image $tag" ([int64] $size)
            $presentBefore += $tag
        }
    }
}

$cacheDir = Join-Path $WorkDir 'cache'
if (Test-Path $cacheDir) { Add-Keep "cache $cacheDir" (Get-DirectoryBytes $cacheDir) }

# --- PURGE ------------------------------------------------------------------
$stoppedContainers = @()
if ($dockerAvailable) {
    $stoppedContainers = @(& docker ps -a --filter 'status=exited' --filter 'status=created' --filter 'status=dead' --format '{{.ID}}' 2>$null | Where-Object { $_ })
    if ($stoppedContainers.Count -gt 0) { Add-Purge "containers (exited/created/dead) x$($stoppedContainers.Count)" 0 }
}

$jobsDir  = Join-Path $WorkDir 'jobs'
$tmpDir   = Join-Path $WorkDir 'tmp'
$logsDir  = Join-Path $WorkDir 'logs'
$proofDir = Join-Path $WorkDir 'proof'

$jobsBytes = [int64] 0
if (Test-Path $jobsDir) { $jobsBytes = Get-DirectoryBytes $jobsDir; Add-Purge "job workspaces $jobsDir" $jobsBytes }

$tmpBytes = [int64] 0
if (Test-Path $tmpDir) { $tmpBytes = Get-DirectoryBytes $tmpDir; Add-Purge "temp downloads $tmpDir" $tmpBytes }

$oldLogs = @()
if (Test-Path $logsDir) {
    $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
    $oldLogs = @(Get-ChildItem -Path $logsDir -Recurse -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($oldLogs.Count -gt 0) {
        $bytes = [int64] (($oldLogs | Measure-Object -Property Length -Sum).Sum)
        Add-Purge "logs older than ${LogRetentionDays}d x$($oldLogs.Count)" $bytes
    }
}

# Proof bundles: keep the most recent, purge older ones. The most recent proof
# is what the Runners page shows as "currently known-good"; deleting it would
# make the GUI claim the setup has never been verified.
$oldProofs = @()
if (Test-Path $proofDir) {
    $bundles = @(Get-ChildItem -Path $proofDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($bundles.Count -gt 1) {
        $newest = $bundles[0]
        $oldProofs = @($bundles | Select-Object -Skip 1)
        $bytes = [int64] 0
        foreach ($bundle in $oldProofs) { $bytes += Get-DirectoryBytes $bundle.FullName }
        Add-Purge "old proof bundles x$($oldProofs.Count) (keeping $($newest.Name))" $bytes
    }
}

Write-Sweep 'KEEP (never deleted):'
foreach ($entry in $keepReport)  { Write-Sweep "  $($entry.item)  ($($entry.bytes) bytes)" }
Write-Sweep 'PURGE:'
foreach ($entry in $purgeReport) { Write-Sweep "  $($entry.item)  ($($entry.bytes) bytes)" }
Write-Sweep "reclaimable: $reclaimableBytes bytes"

if ($DryRun) {
    Write-Sweep 'dry run: nothing was deleted'
}
else {
    Write-Sweep '==> purging'

    if ($stoppedContainers.Count -gt 0) {
        Write-Sweep "removing $($stoppedContainers.Count) stopped container(s)"
        & docker rm -f @stoppedContainers 2>$null | Out-Null
    }

    if (Test-Path $jobsDir) {
        Write-Sweep 'removing job workspaces'
        Get-ChildItem -Path $jobsDir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $reclaimedBytes += $jobsBytes
    }

    if (Test-Path $tmpDir) {
        Write-Sweep "removing this session's temp downloads"
        Get-ChildItem -Path $tmpDir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $reclaimedBytes += $tmpBytes
    }

    foreach ($logFile in $oldLogs)  { Remove-Item -Path $logFile.FullName -Force -ErrorAction SilentlyContinue }
    foreach ($bundle in $oldProofs) { Remove-Item -Path $bundle.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    if ($dockerAvailable) {
        # TARGETED prunes only. `docker image prune -f` removes dangling
        # (untagged) images and never touches a tagged one, so every KEEP tag
        # survives. `docker system prune -a` WOULD delete them and is never used.
        Write-Sweep "pruning dangling images and build cache (never 'system prune -a')"
        $imagePrune   = & docker image prune -f 2>$null | Select-String 'Total reclaimed space'
        $builderPrune = & docker builder prune -f 2>$null | Select-String 'Total'
        if ($imagePrune)   { Write-Sweep "  images:  $imagePrune" }
        if ($builderPrune) { Write-Sweep "  builder: $builderPrune" }
    }

    Write-Sweep "reclaimed at least $reclaimedBytes bytes from tracked directories"

    # Prove the KEEP list survived. A sweeper that quietly ate a base image would
    # otherwise only be discovered by the next build taking an hour.
    if ($dockerAvailable) {
        foreach ($tag in $keepImageTags) {
            if ($presentBefore -notcontains $tag) {
                Write-Sweep "  KEEP not on this host (nothing to verify): $tag"
                continue
            }
            & docker image inspect $tag 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Sweep "  KEEP verified present: $tag" }
            else { Write-Sweep "  ERROR: a KEEP image was present before the sweep and is gone now: $tag" }
        }
        foreach ($volume in $keepVolumes) {
            & docker volume inspect $volume 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Sweep "  KEEP verified present: volume $volume" }
        }
    }
}

if ($ReportJson) {
    $report = [pscustomobject]@{
        reclaimableBytes = $reclaimableBytes
        reclaimedBytes   = $reclaimedBytes
        keep             = @($keepReport)
        purge            = @($purgeReport)
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportJson -Encoding utf8
    Write-Sweep "wrote report to $ReportJson"
}

exit 0
