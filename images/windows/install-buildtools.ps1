<#
.SYNOPSIS
    Installs the win-build toolchain into the image.

.DESCRIPTION
    Every tool this script installs is pinned in versions.toml and reaches this
    script as a URL plus a SHA-256. There is no default for any of them: a
    missing argument is a hard error, never a fall back to "latest".

    Verification is not optional and there is no flag to skip it. If a checksum
    does not match, the build stops and the image is not produced.

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

    [Parameter(Mandatory = $true)] [string] $CMakeUrl,
    [Parameter(Mandatory = $true)] [string] $CMakeSha256,
    [Parameter(Mandatory = $true)] [string] $NinjaUrl,
    [Parameter(Mandatory = $true)] [string] $NinjaSha256,
    [Parameter(Mandatory = $true)] [string] $GitUrl,
    [Parameter(Mandatory = $true)] [string] $GitSha256,
    [Parameter(Mandatory = $true)] [string] $InnoSetupUrl,
    [Parameter(Mandatory = $true)] [string] $InnoSetupSha256,
    [Parameter(Mandatory = $true)] [string] $SevenZipUrl,
    [Parameter(Mandatory = $true)] [string] $SevenZipSha256,
    [Parameter(Mandatory = $true)] [string] $SccacheUrl,
    [Parameter(Mandatory = $true)] [string] $SccacheSha256,
    [Parameter(Mandatory = $true)] [string] $PythonUrl,
    [Parameter(Mandatory = $true)] [string] $PythonSha256,
    [Parameter(Mandatory = $true)] [string] $RunnerUrl,
    [Parameter(Mandatory = $true)] [string] $RunnerSha256,

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

    A checksum that is empty is treated as a HARD ERROR rather than "skip
    verification". An unverified toolchain is worse than a failed build: it is a
    failed build you do not find out about.
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

    $actual = (Get-FileHash -Path $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.ToLowerInvariant()

    if ($actual -ne $expected) {
        throw "CHECKSUM MISMATCH for $Name`n  URL:      $Url`n  expected: $expected`n  actual:   $actual`nThe file at this URL is not the file that was pinned."
    }

    Write-Host "    sha256 ok ($expected)"
}

function Add-ToMachinePath {
    param([Parameter(Mandatory = $true)] [string] $Directory)

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
# passing --channelUri for the specific release channel, which is Microsoft's
# documented mechanism for installing a fixed version.
#
# The ARM64 toolset is what makes the Windows ARM64 output a CROSS-COMPILE rather
# than emulation: an amd64 container hosting the ARM64 compiler.
# ---------------------------------------------------------------------------
Write-Step 'installing Visual Studio Build Tools'
Write-Host "    channel: $VsChannelUrl"

$bootstrapper = Join-Path $downloadDir 'vs_buildtools.exe'
Invoke-WebRequest -Uri $VsBootstrapUrl -OutFile $bootstrapper -UseBasicParsing

$componentList = $VsComponents -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($componentList.Count -eq 0) {
    throw 'No Visual Studio components were supplied. versions.toml must list them.'
}

$vsArgs = @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--channelUri', $VsChannelUrl,
    '--installPath', 'C:\BuildTools'
)
foreach ($component in $componentList) {
    Write-Host "    component: $component"
    $vsArgs += @('--add', $component)
}

$process = Start-Process -FilePath $bootstrapper -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow

# 3010 means "installed, reboot required". A container is never rebooted and the
# toolchain is usable, so it is a success for our purposes.
if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
    throw "Visual Studio Build Tools installation failed with exit code $($process.ExitCode). See C:\\ProgramData\\Microsoft\\VisualStudio\\Packages\\_Instances for logs."
}
Write-Host "    installer exit code $($process.ExitCode)"

# Prove the ARM64 cross toolset really landed. Without this check a missing
# component only surfaces much later, as a confusing CMake failure in CI.
$hostX64 = Get-ChildItem -Path 'C:\BuildTools\VC\Tools\MSVC' -Directory | Select-Object -First 1
if (-not $hostX64) { throw 'No MSVC toolset directory found under C:\BuildTools\VC\Tools\MSVC.' }

foreach ($target in @('x64', 'arm64')) {
    $toolPath = Join-Path $hostX64.FullName "bin\Hostx64\$target\cl.exe"
    if (-not (Test-Path $toolPath)) {
        throw "The $target compiler is missing at $toolPath. Windows ARM64 output is cross-compiled and cannot be produced without the ARM64 toolset."
    }
    Write-Host "    found $target compiler: $toolPath"
}

# ---------------------------------------------------------------------------
# 7-Zip first: it extracts several of the archives below.
# ---------------------------------------------------------------------------
$sevenZipExe = Join-Path $downloadDir '7z-setup.exe'
Get-VerifiedFile -Url $SevenZipUrl -ExpectedSha256 $SevenZipSha256 -Destination $sevenZipExe -Name '7-Zip'
Start-Process -FilePath $sevenZipExe -ArgumentList @('/S', "/D=$ToolsDir\7zip") -Wait -NoNewWindow
$sevenZip = Join-Path $ToolsDir '7zip\7z.exe'
if (-not (Test-Path $sevenZip)) { throw "7-Zip did not install to $sevenZip." }
Add-ToMachinePath -Directory (Join-Path $ToolsDir '7zip')

# ---------------------------------------------------------------------------
# CMake
# ---------------------------------------------------------------------------
$cmakeZip = Join-Path $downloadDir 'cmake.zip'
Get-VerifiedFile -Url $CMakeUrl -ExpectedSha256 $CMakeSha256 -Destination $cmakeZip -Name 'CMake'
Expand-Archive -Path $cmakeZip -DestinationPath "$ToolsDir\cmake-extract" -Force
$cmakeRoot = Get-ChildItem -Path "$ToolsDir\cmake-extract" -Directory | Select-Object -First 1
Move-Item -Path $cmakeRoot.FullName -Destination "$ToolsDir\cmake"
Remove-Item -Recurse -Force "$ToolsDir\cmake-extract"
Add-ToMachinePath -Directory "$ToolsDir\cmake\bin"

# ---------------------------------------------------------------------------
# Ninja
# ---------------------------------------------------------------------------
$ninjaZip = Join-Path $downloadDir 'ninja.zip'
Get-VerifiedFile -Url $NinjaUrl -ExpectedSha256 $NinjaSha256 -Destination $ninjaZip -Name 'Ninja'
Expand-Archive -Path $ninjaZip -DestinationPath "$ToolsDir\ninja" -Force
Add-ToMachinePath -Directory "$ToolsDir\ninja"

# ---------------------------------------------------------------------------
# Git (MinGit: the portable build, which is what a container wants)
# ---------------------------------------------------------------------------
$gitZip = Join-Path $downloadDir 'mingit.zip'
Get-VerifiedFile -Url $GitUrl -ExpectedSha256 $GitSha256 -Destination $gitZip -Name 'Git'
Expand-Archive -Path $gitZip -DestinationPath "$ToolsDir\git" -Force
Add-ToMachinePath -Directory "$ToolsDir\git\cmd"

# ---------------------------------------------------------------------------
# Inno Setup — compiles the Windows installer.
#
# It is installed HERE, into the image, because the build workflow must never
# install it at run time. A job that downloads its own toolchain is a job that
# fails the day the download does.
# ---------------------------------------------------------------------------
$innoExe = Join-Path $downloadDir 'innosetup.exe'
Get-VerifiedFile -Url $InnoSetupUrl -ExpectedSha256 $InnoSetupSha256 -Destination $innoExe -Name 'Inno Setup'
Start-Process -FilePath $innoExe -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=$ToolsDir\innosetup") -Wait -NoNewWindow
$iscc = Join-Path $ToolsDir 'innosetup\ISCC.exe'
if (-not (Test-Path $iscc)) { throw "Inno Setup did not install to $iscc." }
Add-ToMachinePath -Directory "$ToolsDir\innosetup"

# ---------------------------------------------------------------------------
# Python — several build helper scripts assume it exists.
# ---------------------------------------------------------------------------
$pythonExe = Join-Path $downloadDir 'python-installer.exe'
Get-VerifiedFile -Url $PythonUrl -ExpectedSha256 $PythonSha256 -Destination $pythonExe -Name 'Python'
Start-Process -FilePath $pythonExe -ArgumentList @(
    '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0', 'Include_doc=0',
    "TargetDir=$ToolsDir\python"
) -Wait -NoNewWindow
if (-not (Test-Path "$ToolsDir\python\python.exe")) { throw "Python did not install to $ToolsDir\python." }
Add-ToMachinePath -Directory "$ToolsDir\python"

# ---------------------------------------------------------------------------
# sccache — the compiler cache. Paired with the forge-sccache volume, this is
# what makes the second build of the same plugin fast.
# ---------------------------------------------------------------------------
$sccacheArchive = Join-Path $downloadDir 'sccache.tar.gz'
Get-VerifiedFile -Url $SccacheUrl -ExpectedSha256 $SccacheSha256 -Destination $sccacheArchive -Name 'sccache'
New-Item -ItemType Directory -Force -Path "$ToolsDir\sccache-extract" | Out-Null
& $sevenZip x $sccacheArchive "-o$ToolsDir\sccache-extract" -y | Out-Null
$innerTar = Get-ChildItem -Path "$ToolsDir\sccache-extract" -Filter '*.tar' | Select-Object -First 1
if (-not $innerTar) { throw 'sccache archive did not contain the expected .tar.' }
& $sevenZip x $innerTar.FullName "-o$ToolsDir\sccache-extract" -y | Out-Null
$sccacheBinary = Get-ChildItem -Path "$ToolsDir\sccache-extract" -Recurse -Filter 'sccache.exe' | Select-Object -First 1
if (-not $sccacheBinary) { throw 'sccache.exe not found in the extracted archive.' }
New-Item -ItemType Directory -Force -Path "$ToolsDir\sccache" | Out-Null
Move-Item -Path $sccacheBinary.FullName -Destination "$ToolsDir\sccache\sccache.exe"
Remove-Item -Recurse -Force "$ToolsDir\sccache-extract"
Add-ToMachinePath -Directory "$ToolsDir\sccache"

# ---------------------------------------------------------------------------
# The Actions runner.
# ---------------------------------------------------------------------------
$runnerZip = Join-Path $downloadDir 'actions-runner.zip'
Get-VerifiedFile -Url $RunnerUrl -ExpectedSha256 $RunnerSha256 -Destination $runnerZip -Name 'Actions runner'
New-Item -ItemType Directory -Force -Path $RunnerHome | Out-Null
Expand-Archive -Path $runnerZip -DestinationPath $RunnerHome -Force
if (-not (Test-Path (Join-Path $RunnerHome 'run.cmd'))) {
    throw "The Actions runner did not extract to $RunnerHome."
}

# ---------------------------------------------------------------------------
# Cache directories. C:\sdk\aax is created EMPTY on purpose: the Avid SDK is
# mounted there at run time and must never be part of a layer.
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path 'C:\cache\fetchcontent', 'C:\cache\sccache', 'C:\sdk\aax' | Out-Null

Remove-Item -Recurse -Force $downloadDir

Write-Step 'toolchain installed'
Write-Host "    cmake     : $(& "$ToolsDir\cmake\bin\cmake.exe" --version | Select-Object -First 1)"
Write-Host "    ninja     : $(& "$ToolsDir\ninja\ninja.exe" --version)"
Write-Host "    git       : $(& "$ToolsDir\git\cmd\git.exe" --version)"
Write-Host "    python    : $(& "$ToolsDir\python\python.exe" --version)"
Write-Host "    sccache   : $(& "$ToolsDir\sccache\sccache.exe" --version)"
Write-Host "    inno setup: $iscc"
Write-Host "    runner    : $RunnerHome"
