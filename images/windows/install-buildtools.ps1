<#
.SYNOPSIS
    Installs the declared toolchain into the win-build image.

.DESCRIPTION
    THIS SCRIPT NAMES NO TOOL. It installs whatever [toolchain.windows] in
    versions.toml tells it to, so the same image definition serves an audio
    plugin, a Rust project, or anything else. Retarget the runner by editing a
    list, not this file.

    Everything arrives as a manifest of lines:

        <name>|<url>|<sha256>|<kind>|<destination>

    Verification is not optional and there is no flag to skip it. A missing
    checksum is a hard error, not a reason to proceed: an unverified toolchain is
    worse than a failed build, because it is a failed build you do not find out
    about.

    The Avid AAX SDK is deliberately absent. It is proprietary, it cannot live in
    an image layer, and it is mounted from a local named volume at run time.

.NOTES
    Runs inside a Windows container during `docker build`. Nothing here is a
    secret: URLs and checksums are public, which is precisely why they are safe
    to pass as build arguments while credentials never are.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $VsBootstrapUrl,
    [Parameter(Mandatory = $true)] [string] $VsChannelUrl,
    [Parameter(Mandatory = $true)] [string] $VsComponents,
    [Parameter(Mandatory = $true)] [string] $ToolManifest,
    [Parameter(Mandatory = $true)] [string] $RunnerManifest,
    [Parameter(Mandatory = $true)] [string] $RunnerHome,
    [Parameter(Mandatory = $true)] [string] $ToolsDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step { param([string] $Message) Write-Host "==> $Message" }

$downloadDir = 'C:\downloads'
New-Item -ItemType Directory -Force -Path $downloadDir, $ToolsDir | Out-Null

<#
    Downloads a file and verifies its SHA-256 before anyone is allowed to use it.
    An empty checksum is a HARD ERROR rather than "skip verification".
#>
function Get-VerifiedFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Url,
        [Parameter(Mandatory = $true)] [string] $ExpectedSha256,
        [Parameter(Mandatory = $true)] [string] $Destination,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        throw "No SHA-256 recorded for $Name. versions.toml must carry one; verification is never skipped."
    }

    Write-Step "downloading $Name"
    Write-Host "    $Url"

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
    catch {
        # A 404 on a pinned artifact means the pin has rotted. Say exactly which
        # URL failed so the fix is obvious, and never silently reach for 'latest'.
        throw "FAILED TO DOWNLOAD $Name`n  URL: $Url`n  $($_.Exception.Message)`nThe pinned artifact is unavailable. Update versions.toml deliberately; do not fall back to an unpinned version."
    }

    $actual   = (Get-FileHash -Path $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.ToLowerInvariant()

    if ($actual -ne $expected) {
        throw "CHECKSUM MISMATCH for $Name`n  URL:      $Url`n  expected: $expected`n  actual:   $actual`nThe file at this URL is not the file that was pinned."
    }

    Write-Host "    sha256 ok ($expected)"
}

function Add-ToMachinePath {
    param([Parameter(Mandatory = $true)] [string] $Directory)
    if (-not (Test-Path $Directory)) { return }
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($current -notlike "*$Directory*") {
        [Environment]::SetEnvironmentVariable('Path', "$current;$Directory", 'Machine')
    }
    # Also update this process so later steps in the same layer can use the tool.
    $env:Path = "$env:Path;$Directory"
}

# ---------------------------------------------------------------------------
# Visual Studio Build Tools.
#
# Microsoft ships only an evergreen bootstrapper, so there is no per-version .exe
# URL and therefore no checksum to record. The VERSION is pinned instead by
# passing --channelUri for a specific release channel, which is Microsoft's
# documented mechanism for installing a fixed version.
#
# Which components get installed is declared in versions.toml, not here.
# ---------------------------------------------------------------------------
Write-Step 'installing Visual Studio Build Tools'
Write-Host "    channel: $VsChannelUrl"

$bootstrapper = Join-Path $downloadDir 'vs_buildtools.exe'
Invoke-WebRequest -Uri $VsBootstrapUrl -OutFile $bootstrapper -UseBasicParsing

$componentList = $VsComponents -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($componentList.Count -eq 0) {
    throw 'No Visual Studio components were supplied. [toolchain.windows].vs_components must list them.'
}

$vsArgs = @('--quiet', '--wait', '--norestart', '--nocache',
            '--channelUri', $VsChannelUrl, '--installPath', 'C:\BuildTools')
foreach ($component in $componentList) {
    Write-Host "    component: $component"
    $vsArgs += @('--add', $component)
}

$process = Start-Process -FilePath $bootstrapper -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow

# 3010 means "installed, reboot required". A container is never rebooted and the
# toolchain is usable, so it is a success for our purposes.
if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
    throw "Visual Studio Build Tools installation failed with exit code $($process.ExitCode). See C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances for logs."
}
Write-Host "    installer exit code $($process.ExitCode)"

# If an ARM64 toolset was requested, prove it actually landed. A missing
# component otherwise surfaces much later as a confusing CMake failure in CI.
$msvcRoot = Get-ChildItem -Path 'C:\BuildTools\VC\Tools\MSVC' -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1
if ($msvcRoot) {
    foreach ($target in @('x64', 'arm64')) {
        $requested = $componentList -match "VC\.Tools\.$([regex]::Escape($target))" -or $target -eq 'x64'
        $toolPath = Join-Path $msvcRoot.FullName "bin\Hostx64\$target\cl.exe"
        if (Test-Path $toolPath) {
            Write-Host "    found $target compiler: $toolPath"
        }
        elseif ($requested) {
            throw "The $target compiler is missing at $toolPath, but a toolset for it was requested. Windows ARM64 output is cross-compiled and cannot be produced without it."
        }
    }
}

# ---------------------------------------------------------------------------
# The declared toolchain. One generic loop; adding a tool means adding a line to
# versions.toml, never editing this script.
#
# Install kinds:
#   zip-flat     unzip into the destination
#   zip-strip1   unzip, then hoist the single top-level directory
#   targz-find   extract a .tar.gz (via 7-Zip) and hoist the named executable
#   exe-silent   run an NSIS-style installer with /S /D=<dest>
#   exe-inno     run an Inno Setup installer with /VERYSILENT /DIR=<dest>
#   exe-python   run the python.org installer with TargetDir=<dest>
# ---------------------------------------------------------------------------
$sevenZip = $null

function Install-Tool {
    param([string] $Name, [string] $Url, [string] $Sha, [string] $Kind, [string] $Dest)

    $extension = if ($Kind -like 'exe-*') { '.exe' } elseif ($Kind -like 'targz*') { '.tar.gz' } else { '.zip' }
    $archive = Join-Path $downloadDir ("$Name$extension")

    Get-VerifiedFile -Url $Url -ExpectedSha256 $Sha -Destination $archive -Name $Name

    switch ($Kind) {
        'zip-flat' {
            Expand-Archive -Path $archive -DestinationPath $Dest -Force
        }
        'zip-strip1' {
            $staging = "$Dest-extract"
            Expand-Archive -Path $archive -DestinationPath $staging -Force
            $inner = Get-ChildItem -Path $staging -Directory | Select-Object -First 1
            if (-not $inner) { throw "$Name archive had no top-level directory to strip." }
            Move-Item -Path $inner.FullName -Destination $Dest
            Remove-Item -Recurse -Force $staging
        }
        'targz-find' {
            if (-not $script:sevenZip) { throw "$Name needs 7-Zip, which must be listed before it in tools_base." }
            $staging = "$Dest-extract"
            New-Item -ItemType Directory -Force -Path $staging | Out-Null
            & $script:sevenZip x $archive "-o$staging" -y | Out-Null
            $innerTar = Get-ChildItem -Path $staging -Filter '*.tar' | Select-Object -First 1
            if (-not $innerTar) { throw "$Name archive did not contain the expected .tar." }
            & $script:sevenZip x $innerTar.FullName "-o$staging" -y | Out-Null
            $binary = Get-ChildItem -Path $staging -Recurse -Filter "$($Name.Split('_')[0]).exe" | Select-Object -First 1
            if (-not $binary) { $binary = Get-ChildItem -Path $staging -Recurse -Filter '*.exe' | Select-Object -First 1 }
            if (-not $binary) { throw "${Name}: no executable found in the extracted archive." }
            New-Item -ItemType Directory -Force -Path $Dest | Out-Null
            Move-Item -Path $binary.FullName -Destination (Join-Path $Dest $binary.Name)
            Remove-Item -Recurse -Force $staging
        }
        'exe-silent' {
            Start-Process -FilePath $archive -ArgumentList @('/S', "/D=$Dest") -Wait -NoNewWindow
        }
        'exe-inno' {
            Start-Process -FilePath $archive -ArgumentList @(
                '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=$Dest") -Wait -NoNewWindow
        }
        'exe-python' {
            Start-Process -FilePath $archive -ArgumentList @(
                '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0', 'Include_doc=0',
                "TargetDir=$Dest") -Wait -NoNewWindow
        }
        default { throw "unknown install kind '$Kind' for $Name" }
    }

    if (-not (Test-Path $Dest)) { throw "$Name did not install to $Dest." }

    # Both layouts are covered without naming any tool: some ship bin/, some are
    # a bare directory of executables.
    Add-ToMachinePath -Directory $Dest
    Add-ToMachinePath -Directory (Join-Path $Dest 'bin')
    Add-ToMachinePath -Directory (Join-Path $Dest 'cmd')

    Remove-Item -Force $archive -ErrorAction SilentlyContinue
    Write-Host "    installed to $Dest"
}

foreach ($line in ($ToolManifest -split "`n")) {
    $entry = $line.Trim()
    if (-not $entry) { continue }
    $parts = $entry -split '\|'
    if ($parts.Count -lt 5) { throw "malformed toolchain manifest entry: $entry" }

    Install-Tool -Name $parts[0] -Url $parts[1] -Sha $parts[2] -Kind $parts[3] -Dest $parts[4]

    # 7-Zip, once installed, is what later archive kinds use. Discovered by
    # looking for the binary rather than by hardcoding the tool's name.
    if (-not $script:sevenZip) {
        $candidate = Join-Path $parts[4] '7z.exe'
        if (Test-Path $candidate) { $script:sevenZip = $candidate }
    }
}

# ---------------------------------------------------------------------------
# The Actions runner. Separate because it is not a build tool and is not on PATH.
# ---------------------------------------------------------------------------
$runnerParts = ($RunnerManifest.Trim() -split '\|')
if ($runnerParts.Count -lt 4) { throw "malformed runner manifest: $RunnerManifest" }

$runnerArchive = Join-Path $downloadDir 'actions-runner.zip'
Get-VerifiedFile -Url $runnerParts[1] -ExpectedSha256 $runnerParts[2] -Destination $runnerArchive -Name $runnerParts[0]
New-Item -ItemType Directory -Force -Path $RunnerHome | Out-Null
Expand-Archive -Path $runnerArchive -DestinationPath $RunnerHome -Force
if (-not (Test-Path (Join-Path $RunnerHome 'run.cmd'))) {
    throw "The Actions runner did not extract to $RunnerHome."
}

# ---------------------------------------------------------------------------
# Cache directories. C:\sdk\aax is created EMPTY on purpose: the Avid SDK is
# mounted there at run time and must never be part of a layer.
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path 'C:\cache\fetchcontent', 'C:\cache\sccache', 'C:\sdk\aax' | Out-Null

Remove-Item -Recurse -Force $downloadDir -ErrorAction SilentlyContinue

Write-Step 'toolchain installed'
Get-ChildItem -Path $ToolsDir -Directory | ForEach-Object { Write-Host "    $($_.Name) -> $($_.FullName)" }
Write-Host "    runner -> $RunnerHome"
