<#
.SYNOPSIS
    Windows host preflight for Runner Forge.

.DESCRIPTION
    Says exactly what is missing on this machine, and which of it can be fixed
    automatically. The GUI renders these results as rows with a status pill and a
    Fix button; this script is the engine behind that page and is equally usable
    from a terminal.

    Emits a JSON array with -Json so the GUI consumes structured results rather
    than parsing console text.

    Each check reports one of:
      Pass  the requirement is met
      Warn  not met, but only some runner classes are affected
      Fail  not met, and the affected classes cannot run at all

    Windows Home is a hard Fail with no workaround. Windows containers require
    Hyper-V isolation, which Home does not provide. Saying so here is far kinder
    than letting the user discover it three failed builds later.

.PARAMETER Fix
    Apply the automatic fixes for checks that have one. Fixes that require a
    reboot say so and never reboot on their own.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [int]    $MaxDiskGb = 120,
    [Parameter(Mandatory = $false)] [string] $DockerDesktopMinimum = '4.37.0',
    [Parameter(Mandatory = $false)] [int]    $WindowsBuildMinimum = 22000,
    [Parameter(Mandatory = $false)] [string] $SigningMode = 'windows-ilok',
    [Parameter(Mandatory = $false)] [switch] $Fix,
    [Parameter(Mandatory = $false)] [switch] $Json
)

$ErrorActionPreference = 'Continue'

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string] $Name,
        [ValidateSet('Pass', 'Warn', 'Fail')] [string] $Status,
        [string] $Detail,
        [string] $FixHint = '',
        [bool]   $AutoFixable = $false,
        [string] $BlocksClasses = ''
    )
    $results.Add([pscustomobject]@{
        name          = $Name
        status        = $Status
        detail        = $Detail
        fixHint       = $FixHint
        autoFixable   = $AutoFixable
        blocksClasses = $BlocksClasses
    })
}

function Test-IsWindows { $IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT') }

if (-not (Test-IsWindows)) {
    Add-Result -Name 'Host operating system' -Status 'Fail' `
        -Detail "This preflight targets Windows; it is running on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)." `
        -BlocksClasses 'win-build,linux-util,win-ilok'
    if ($Json) { $results | ConvertTo-Json -Depth 4 } else { $results | Format-Table -AutoSize }
    exit 1
}

# --- 1. Windows edition ------------------------------------------------------
try {
    $edition = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($edition -match 'Home') {
        Add-Result -Name 'Windows edition' -Status 'Fail' `
            -Detail "$edition. Windows containers require Hyper-V isolation, which Home does not provide. There is no supported workaround: not WSL, not process isolation, not a third-party shim." `
            -FixHint 'Upgrade to Windows 11 Pro or Enterprise.' `
            -BlocksClasses 'win-build'
    }
    else {
        Add-Result -Name 'Windows edition' -Status 'Pass' -Detail $edition
    }
}
catch {
    Add-Result -Name 'Windows edition' -Status 'Warn' -Detail "Could not determine the edition: $($_.Exception.Message)"
}

# --- 2. Build number ---------------------------------------------------------
try {
    $build = [int] (Get-CimInstance Win32_OperatingSystem).BuildNumber
    if ($build -ge $WindowsBuildMinimum) {
        Add-Result -Name 'Windows build number' -Status 'Pass' -Detail "build $build (minimum $WindowsBuildMinimum)"
    }
    else {
        Add-Result -Name 'Windows build number' -Status 'Fail' `
            -Detail "build $build is below the minimum $WindowsBuildMinimum required for ltsc2022 container compatibility." `
            -FixHint 'Install the latest Windows feature update.' -BlocksClasses 'win-build'
    }
}
catch {
    Add-Result -Name 'Windows build number' -Status 'Warn' -Detail "Could not determine the build number: $($_.Exception.Message)"
}

# --- 3. Hardware virtualization ---------------------------------------------
try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cpu.VirtualizationFirmwareEnabled -eq $true -or $cpu.SecondLevelAddressTranslationExtensions -eq $true) {
        Add-Result -Name 'Hardware virtualization' -Status 'Pass' -Detail 'enabled in firmware'
    }
    else {
        Add-Result -Name 'Hardware virtualization' -Status 'Fail' `
            -Detail 'Virtualization is disabled in firmware. Hyper-V cannot start without it.' `
            -FixHint 'Enable Intel VT-x / AMD-V in your UEFI firmware settings. This cannot be changed from Windows.' `
            -BlocksClasses 'win-build,linux-util'
    }
}
catch {
    Add-Result -Name 'Hardware virtualization' -Status 'Warn' -Detail "Could not query the CPU: $($_.Exception.Message)"
}

# --- 4. Windows features -----------------------------------------------------
$featureNames = @('Microsoft-Hyper-V', 'Containers')
foreach ($feature in $featureNames) {
    try {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop).State
        if ($state -eq 'Enabled') {
            Add-Result -Name "Windows feature: $feature" -Status 'Pass' -Detail 'enabled'
        }
        else {
            if ($Fix) {
                Write-Host "[preflight] enabling $feature via DISM"
                & dism.exe /Online /Enable-Feature /FeatureName:$feature /All /NoRestart | Out-Null
                Add-Result -Name "Windows feature: $feature" -Status 'Warn' `
                    -Detail 'enabled; a REBOOT is required before it takes effect' `
                    -FixHint 'Reboot this machine.' -AutoFixable $true -BlocksClasses 'win-build'
            }
            else {
                Add-Result -Name "Windows feature: $feature" -Status 'Fail' -Detail "state is $state" `
                    -FixHint "dism.exe /Online /Enable-Feature /FeatureName:$feature /All /NoRestart, then reboot" `
                    -AutoFixable $true -BlocksClasses 'win-build'
            }
        }
    }
    catch {
        Add-Result -Name "Windows feature: $feature" -Status 'Warn' -Detail "Could not query the feature: $($_.Exception.Message)"
    }
}

# --- 5. Docker Desktop installed --------------------------------------------
function Compare-Version {
    param([string] $Actual, [string] $Minimum)
    try { return ([version] $Actual) -ge ([version] $Minimum) } catch { return $false }
}

$dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCommand) {
    Add-Result -Name 'Docker Desktop installed' -Status 'Fail' `
        -Detail 'docker is not on PATH.' `
        -FixHint "Install Docker Desktop $DockerDesktopMinimum or newer." `
        -BlocksClasses 'win-build,linux-util'
}
else {
    $dockerVersion = (& docker version --format '{{.Client.Version}}' 2>$null)
    if ($dockerVersion -and (Compare-Version -Actual $dockerVersion -Minimum $DockerDesktopMinimum)) {
        Add-Result -Name 'Docker Desktop installed' -Status 'Pass' -Detail "client $dockerVersion (minimum $DockerDesktopMinimum)"
    }
    else {
        Add-Result -Name 'Docker Desktop installed' -Status 'Warn' `
            -Detail "client version '$dockerVersion' is below the pinned minimum $DockerDesktopMinimum." `
            -FixHint 'Update Docker Desktop.' -BlocksClasses 'win-build,linux-util'
    }
}

# --- 6. Docker daemon reachable ---------------------------------------------
# Deliberately separate from check 5: "installed" and "answering" fail
# independently and have different fixes.
if ($dockerCommand) {
    & docker info 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Add-Result -Name 'Docker daemon reachable' -Status 'Pass' -Detail 'the daemon is answering'
    }
    else {
        Add-Result -Name 'Docker daemon reachable' -Status 'Fail' `
            -Detail 'docker is installed but the daemon is not answering.' `
            -FixHint 'Start Docker Desktop and wait for the whale icon to stop animating. If it never settles, check %LOCALAPPDATA%\Docker\log.txt.' `
            -BlocksClasses 'win-build,linux-util'
    }
}

# --- 7. Windows containers mode ---------------------------------------------
if ($dockerCommand) {
    $osType = (& docker info --format '{{.OSType}}' 2>$null)
    if ($osType -eq 'windows') {
        Add-Result -Name 'Docker in Windows containers mode' -Status 'Pass' -Detail 'OSType=windows'
    }
    elseif ($osType) {
        $dockerCli = Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe'
        if ($Fix -and (Test-Path $dockerCli)) {
            Write-Host '[preflight] switching Docker to the Windows engine'
            & $dockerCli -SwitchWindowsEngine
            Add-Result -Name 'Docker in Windows containers mode' -Status 'Warn' `
                -Detail 'switch requested; Docker Desktop needs a moment to restart the engine' -AutoFixable $true
        }
        else {
            Add-Result -Name 'Docker in Windows containers mode' -Status 'Fail' `
                -Detail "OSType=$osType. win-build is a Windows container and cannot run on the Linux engine." `
                -FixHint '"%ProgramFiles%\Docker\Docker\DockerCli.exe" -SwitchWindowsEngine' `
                -AutoFixable $true -BlocksClasses 'win-build'
        }
    }
}

# --- 8. WSL2 -----------------------------------------------------------------
if (Get-Command wsl -ErrorAction SilentlyContinue) {
    $distros = @(& wsl --list --quiet 2>$null | Where-Object { $_ -and $_.Trim() })
    if ($distros.Count -gt 0) {
        Add-Result -Name 'WSL2 with a distribution' -Status 'Pass' -Detail "$($distros.Count) distribution(s) installed"
    }
    else {
        Add-Result -Name 'WSL2 with a distribution' -Status 'Warn' `
            -Detail 'WSL is present but no distribution is installed. Only linux-util is affected.' `
            -FixHint 'wsl --install -d Ubuntu' -BlocksClasses 'linux-util'
    }
}
else {
    Add-Result -Name 'WSL2 with a distribution' -Status 'Warn' `
        -Detail 'wsl is not on PATH. Only linux-util is affected.' `
        -FixHint 'wsl --install' -BlocksClasses 'linux-util'
}

# --- 9. Free disk ------------------------------------------------------------
try {
    $dockerRoot = (& docker info --format '{{.DockerRootDir}}' 2>$null)
    $driveLetter = if ($dockerRoot -and $dockerRoot -match '^([A-Za-z]):') { $Matches[1] } else { $env:SystemDrive.TrimEnd(':') }
    $drive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGb -ge $MaxDiskGb) {
        Add-Result -Name 'Free disk space' -Status 'Pass' -Detail "$freeGb GB free on ${driveLetter}: (minimum $MaxDiskGb GB)"
    }
    else {
        Add-Result -Name 'Free disk space' -Status 'Fail' `
            -Detail "$freeGb GB free on ${driveLetter}:, below the configured minimum of $MaxDiskGb GB. The Windows image alone is several GB." `
            -FixHint 'Free space, or lower limits.maxDiskGb in forge.json if you know what you are doing.' `
            -BlocksClasses 'win-build,linux-util'
    }
}
catch {
    Add-Result -Name 'Free disk space' -Status 'Warn' -Detail "Could not determine free space: $($_.Exception.Message)"
}

# --- 10. Sleep on AC ---------------------------------------------------------
try {
    $powerOutput = & powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null | Out-String
    if ($powerOutput -match 'Current AC Power Setting Index:\s*0x00000000') {
        Add-Result -Name 'Sleep on AC disabled' -Status 'Pass' -Detail 'standby timeout on AC is 0 (never)'
    }
    else {
        if ($Fix) {
            & powercfg /change standby-timeout-ac 0
            Add-Result -Name 'Sleep on AC disabled' -Status 'Pass' -Detail 'standby timeout on AC set to 0' -AutoFixable $true
        }
        else {
            Add-Result -Name 'Sleep on AC disabled' -Status 'Warn' `
                -Detail 'This machine can sleep on AC power. A sleeping host drops in-flight jobs.' `
                -FixHint 'powercfg /change standby-timeout-ac 0' -AutoFixable $true
        }
    }
}
catch {
    Add-Result -Name 'Sleep on AC disabled' -Status 'Warn' -Detail "Could not query the power scheme: $($_.Exception.Message)"
}

# --- 11. Outbound HTTPS ------------------------------------------------------
foreach ($endpoint in @('github.com', 'api.github.com', 'ghcr.io', 'mcr.microsoft.com')) {
    try {
        $response = Invoke-WebRequest -Uri "https://$endpoint" -Method Head -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        Add-Result -Name "Outbound HTTPS: $endpoint" -Status 'Pass' -Detail "HTTP $($response.StatusCode)"
    }
    catch {
        # A 4xx still proves reachability; only a transport failure is a problem.
        $status = $null
        if ($_.Exception.Response) { $status = [int] $_.Exception.Response.StatusCode }
        if ($status) {
            Add-Result -Name "Outbound HTTPS: $endpoint" -Status 'Pass' -Detail "HTTP $status (reachable)"
        }
        else {
            Add-Result -Name "Outbound HTTPS: $endpoint" -Status 'Fail' `
                -Detail "unreachable: $($_.Exception.Message)" `
                -FixHint 'Check your firewall, proxy, or corporate TLS inspection settings.' `
                -BlocksClasses 'win-build,linux-util,win-ilok'
        }
    }
}

# --- 12. Base images present (informational) --------------------------------
if ($dockerCommand) {
    foreach ($image in @('runnerforge/win-build', 'runnerforge/linux-util')) {
        $found = @(& docker images $image --format '{{.Repository}}:{{.Tag}}' 2>$null | Where-Object { $_ })
        if ($found.Count -gt 0) {
            Add-Result -Name "Base image: $image" -Status 'Pass' -Detail ($found -join ', ')
        }
        else {
            Add-Result -Name "Base image: $image" -Status 'Warn' `
                -Detail 'not built yet. This is informational: the first build takes a while but only happens once.' `
                -FixHint 'Use "Rebuild image" on the Runners page.' -AutoFixable $true
        }
    }
}

# --- 13. iLok, only in windows-ilok mode ------------------------------------
if ($SigningMode -eq 'windows-ilok') {
    $paceService = Get-Service -Name 'PACE License Services' -ErrorAction SilentlyContinue
    if ($paceService) {
        Add-Result -Name 'iLok driver' -Status 'Pass' -Detail "PACE License Services is $($paceService.Status)"
    }
    else {
        Add-Result -Name 'iLok driver' -Status 'Fail' `
            -Detail 'The PACE License Services driver is not installed.' `
            -FixHint 'Install iLok License Manager, which installs the driver.' -BlocksClasses 'win-ilok'
    }

    # A USB dongle is a HID/USB device; a container can never see it, which is
    # exactly why win-ilok is a host process and not a container.
    $dongle = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match 'iLok' -or $_.PNPDeviceID -match 'VID_088E' }
    if ($dongle) {
        Add-Result -Name 'iLok dongle detected' -Status 'Pass' -Detail (@($dongle)[0].Name)
    }
    else {
        Add-Result -Name 'iLok dongle detected' -Status 'Fail' `
            -Detail 'No iLok USB device found. Note that a Windows container can never see one; win-ilok is deliberately a host process.' `
            -FixHint 'Plug the dongle into this machine, or switch signing.mode to "cloud".' -BlocksClasses 'win-ilok'
    }

    if (Get-Command wraptool -ErrorAction SilentlyContinue) {
        Add-Result -Name 'wraptool on PATH' -Status 'Pass' -Detail (Get-Command wraptool).Source
    }
    else {
        Add-Result -Name 'wraptool on PATH' -Status 'Fail' `
            -Detail 'wraptool.exe is not on PATH.' `
            -FixHint 'Install PACE Eden tools and add its bin directory to PATH.' -BlocksClasses 'win-ilok'
    }
}
else {
    Add-Result -Name 'iLok checks' -Status 'Pass' -Detail "skipped: signing.mode is '$SigningMode', which needs no dongle on this host"
}

# --- output ------------------------------------------------------------------
if ($Json) {
    $results | ConvertTo-Json -Depth 4
}
else {
    $results | Format-Table -Property status, name, detail -AutoSize -Wrap
    Write-Host ''
    Write-Host ("Pass {0}   Warn {1}   Fail {2}" -f `
        @($results | Where-Object status -eq 'Pass').Count,
        @($results | Where-Object status -eq 'Warn').Count,
        @($results | Where-Object status -eq 'Fail').Count)
}

# A single Fail is enough to block: the affected classes cannot run.
if (@($results | Where-Object status -eq 'Fail').Count -gt 0) { exit 1 }
exit 0
