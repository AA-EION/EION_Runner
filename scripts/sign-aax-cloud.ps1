<#
.SYNOPSIS
    AAX signing on Windows WITHOUT a physical iLok.

.DESCRIPTION
    Two different PACE products share the word "cloud", and confusing them
    wastes a day:

        iLok Cloud    - PACE's internet licensing system. An open Cloud session
                        makes your PACE Tools license available to wraptool on a
                        machine with no iLok plugged in. Opened with iloktool,
                        which ships with iLok License Manager, NOT with the SDK.

        Cloud Signing - the subscription service that performs the signature
                        when no signing iLok is present. Enabled per invocation
                        with wraptool's --allowsigningservice.

    A CI runner with no hardware needs BOTH: the session authorizes the tool,
    the flag authorizes the signature.

    An earlier version of this script called `wraptool activate --cloud` and
    `wraptool deactivate`. Neither command exists. The session is `iloktool
    cloud --open` / `--close`.

    CREDENTIALS AND ARGV. wraptool reads PF_ACCOUNT_ID / PF_ACCOUNT_PASSWORD
    from the environment, so the signing call carries no secret in its argument
    list. `iloktool cloud --open` is the exception: PACE documents only
    --account and --password for it and no environment equivalent, which is why
    opening a session is OPT-IN here via -OpenSession. Prefer opening the
    session once by hand — it persists until explicitly closed, so routine runs
    never need the password.

    Parameters are -InputPath/-OutputPath and NOT -Input/-Output on purpose:
    $Input is an AUTOMATIC variable in PowerShell. Do not rename them back.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$SignId = '',
    [string]$KeyFile = '',
    [string]$WcGuid = '',
    [string]$CustomerNumber = '',
    [string]$CustomerName = '',
    [string]$ProductName = '',
    [string]$OutputPath = '',
    [string]$SignTool = '',

    [switch]$OpenSession,
    [switch]$CloseSession,
    [switch]$SelfSigned,
    [switch]$Sha1Legacy,
    [switch]$DryRun,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Message) Write-Host "[sign-aax-cloud] $Message" }

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }

if (-not $SignId -and -not $KeyFile) {
    Write-Host 'error: on Windows you must give either -SignId (a certificate thumbprint' -ForegroundColor Red
    Write-Host '       in the Personal store) or -KeyFile (a PKCS#12 file).' -ForegroundColor Red
    exit 2
}
if (-not $WcGuid -and -not $CustomerNumber) {
    Write-Host 'error: the publisher must be identified by -WcGuid, or by -CustomerNumber' -ForegroundColor Red
    Write-Host '       together with -CustomerName.' -ForegroundColor Red
    exit 2
}
if ($CustomerNumber -and -not $CustomerName) {
    Write-Host 'error: -CustomerNumber requires -CustomerName; wraptool rejects it alone.' -ForegroundColor Red
    exit 2
}

# wraptool sign is IN PLACE on Windows. See sign-aax-ilok.ps1 for the full note.
if ($OutputPath -and ($OutputPath -ne $InputPath)) {
    Write-Host 'error: on Windows wraptool sign operates IN PLACE — --in and --out must be' -ForegroundColor Red
    Write-Host '       the same path. Copy the bundle to its final location FIRST, then sign' -ForegroundColor Red
    Write-Host '       it there. If you rename an .aaxplugin bundle, rename the inner binary' -ForegroundColor Red
    Write-Host '       too: MyPlugin.aaxplugin\Contents\x64\MyPlugin.aaxplugin' -ForegroundColor Red
    exit 2
}

# --allowsigningservice is documented as requiring BOTH the account and the
# password. Fail here, in a second, rather than after a twenty-minute build.
$missing = @()
if (-not $env:PACE_ACCOUNT)  { $missing += 'PACE_ACCOUNT' }
if (-not $env:PACE_PASSWORD) { $missing += 'PACE_PASSWORD' }
if ($missing.Count -gt 0) {
    Write-Host 'error: cloud signing needs both of these, and they are absent:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host '' -ForegroundColor Red
    Write-Host 'PACE requires an account and password for --allowsigningservice; unlike' -ForegroundColor Red
    Write-Host 'the iLok path, an ILM login is not enough. They live in the OS keystore' -ForegroundColor Red
    Write-Host '(paceAccount / pacePassword) and are injected as environment variables.' -ForegroundColor Red
    Write-Host 'Never put them in forge.json.' -ForegroundColor Red
    exit 3
}

function Find-Wraptool {
    if ($env:WRAPTOOL) { if (Test-Path $env:WRAPTOOL) { return $env:WRAPTOOL } else { return $null } }
    $onPath = Get-Command wraptool -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $roots = @(
        "$env:ProgramFiles\PACEAntiPiracy\Eden\Fusion\Versions",
        "${env:ProgramFiles(x86)}\PACEAntiPiracy\Eden\Fusion\Versions"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [int]($_.Name -replace '\D', '0') } -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\wraptool.exe' } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($found) { return $found }
    }
    return $null
}

function Find-Iloktool {
    if ($env:ILOKTOOL) { if (Test-Path $env:ILOKTOOL) { return $env:ILOKTOOL } else { return $null } }
    $onPath = Get-Command iloktool -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    # iLok License Manager installs 32-bit by default, so this path is correct
    # even on 64-bit Windows.
    $candidates = @(
        "${env:ProgramFiles(x86)}\iLok License Manager\iloktool.exe",
        "$env:ProgramFiles\iLok License Manager\iloktool.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

$wraptool = $null
if (-not $DryRun) {
    $wraptool = Find-Wraptool
    if (-not $wraptool) {
        Write-Host 'error: wraptool.exe was not found on PATH or under' -ForegroundColor Red
        Write-Host '       %ProgramFiles%\PACEAntiPiracy\Eden\Fusion\Versions\*\bin\wraptool.exe' -ForegroundColor Red
        exit 3
    }
    Write-Log "wraptool: $wraptool"
    if (-not (Test-Path $InputPath)) {
        Write-Host "error: input does not exist: $InputPath" -ForegroundColor Red
        exit 2
    }
}

# ---------------------------------------------------------------------------
# The iLok Cloud session, and the finally block that closes it.
# ---------------------------------------------------------------------------
$sessionOpened = $false
$iloktool = $null

try {
    if ($OpenSession) {
        if ($DryRun) {
            Write-Host '[dry-run] iloktool cloud --open --account <PACE_ACCOUNT> --password <redacted> -v'
        }
        else {
            $iloktool = Find-Iloktool
            if (-not $iloktool) {
                Write-Host 'error: iloktool.exe was not found.' -ForegroundColor Red
                Write-Host '       It installs with iLok License Manager (the License Support installer' -ForegroundColor Red
                Write-Host '       from ilok.com), NOT with the Fusion SDK. Default location:' -ForegroundColor Red
                Write-Host '         C:\Program Files (x86)\iLok License Manager\iloktool.exe' -ForegroundColor Red
                Write-Host '       Alternatively open the Cloud session by hand from iLok License' -ForegroundColor Red
                Write-Host '       Manager: File > Open Your Cloud Session, and drop -OpenSession.' -ForegroundColor Red
                exit 3
            }
            Write-Log 'opening an iLok Cloud session'
            Write-Log 'NOTE: this is the one call whose documented CLI takes the password as an'
            Write-Log '      argument. Open the session once by hand and it persists, so routine'
            Write-Log '      runs need neither this flag nor the password.'
            & $iloktool cloud --open --account $env:PACE_ACCOUNT --password $env:PACE_PASSWORD -v
            if ($LASTEXITCODE -ne 0) {
                Write-Host 'error: could not open an iLok Cloud session.' -ForegroundColor Red
                Write-Host '       Check that this account holds a Cloud-enabled PACE Tools license,' -ForegroundColor Red
                Write-Host '       and that no physical iLok with PACE Tools activated is connected —' -ForegroundColor Red
                Write-Host '       PACE documents that combination as a conflict.' -ForegroundColor Red
                Write-Host '       A Cloud session also cannot be shared across machines: each build' -ForegroundColor Red
                Write-Host '       machine needs its own iLok account.' -ForegroundColor Red
                exit 3
            }
            $sessionOpened = $true
        }
    }

    # -----------------------------------------------------------------------
    # Sign. --allowsigningservice is what makes this work with no signing iLok.
    # -----------------------------------------------------------------------
    $wraptoolArgs = @('sign', '--verbose', '--in', $InputPath, '--allowsigningservice')

    if ($SignId)         { $wraptoolArgs += @('--signid', $SignId) }
    if ($KeyFile)        { $wraptoolArgs += @('--keyfile', $KeyFile) }
    if ($WcGuid)         { $wraptoolArgs += @('--wcguid', $WcGuid) }
    if ($CustomerNumber) { $wraptoolArgs += @('--customernumber', $CustomerNumber) }
    if ($CustomerName)   { $wraptoolArgs += @('--customername', $CustomerName) }
    if ($ProductName)    { $wraptoolArgs += @('--productname', $ProductName) }
    if ($SignTool)       { $wraptoolArgs += @('--signtool', $SignTool) }

    if (-not $Sha1Legacy) {
        $wraptoolArgs += @('--extrasigningoptions', 'digest_sha256')
    } else {
        Write-Log 'WARNING: -Sha1Legacy given. SHA-1 is deprecated and modern Windows rejects it.'
    }

    if ($SelfSigned) {
        Write-Log 'self-signed mode: Windows will not trust this signature on any machine that'
        Write-Log '  has not been told to trust the certificate. The PACE signature is'
        Write-Log '  unaffected — Pro Tools checks that, not Authenticode. See docs/SIGNING.md.'
    }

    if ($DryRun) {
        $printable = ($wraptoolArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
        Write-Host '[dry-run] $env:PF_ACCOUNT_ID=<PACE_ACCOUNT>; $env:PF_ACCOUNT_PASSWORD=<redacted>'
        Write-Host "[dry-run]   wraptool $printable"
        Write-Log 'dry run: inputs validated, nothing signed, no credentials on any wraptool command line'
        exit 0
    }

    Write-Log "signing $InputPath in place through the PACE signing service"

    $previousId = $env:PF_ACCOUNT_ID
    $previousPw = $env:PF_ACCOUNT_PASSWORD
    try {
        $env:PF_ACCOUNT_ID = $env:PACE_ACCOUNT
        $env:PF_ACCOUNT_PASSWORD = $env:PACE_PASSWORD
        $signOutput = & $wraptool @wraptoolArgs 2>&1 | Tee-Object -Variable teed | Out-String
        $signExit = $LASTEXITCODE
    }
    finally {
        $env:PF_ACCOUNT_ID = $previousId
        $env:PF_ACCOUNT_PASSWORD = $previousPw
    }

    $teed | ForEach-Object { Write-Host $_ }

    if ($signExit -ne 0) {
        Write-Host ''
        Write-Host "error: wraptool sign failed. The message above is PACE's, verbatim." -ForegroundColor Red
        switch -Regex ($signOutput) {
            'CouldNotFindSignerCredentials' {
                Write-Host '  -> With --allowsigningservice this means the service could not authorize' -ForegroundColor Red
                Write-Host '     the signature. Check internet access, that PACE_ACCOUNT/PACE_PASSWORD' -ForegroundColor Red
                Write-Host '     are right, and that an iLok Cloud session is open for this account.' -ForegroundColor Red
                break
            }
            'MissingFusionToolsLicense' {
                Write-Host '  -> No PACE Tools license is reachable. Cloud signing needs a' -ForegroundColor Red
                Write-Host '     Cloud-enabled PACE Tools license and an open iLok Cloud session.' -ForegroundColor Red
                break
            }
            'InvalidPassword' {
                Write-Host '  -> PACE_PASSWORD was rejected. Re-enter it on the Credentials page.' -ForegroundColor Red
                break
            }
        }
        Write-Host '     A licensing error here often means the account is not subscribed to the' -ForegroundColor Red
        Write-Host '     Cloud Signing service, which --allowsigningservice cannot grant by itself.' -ForegroundColor Red
        exit 4
    }

    Write-Log 'verifying the signature'
    & $wraptool verify --verbose --in $InputPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'error: the signed bundle failed wraptool verify.' -ForegroundColor Red
        exit 4
    }

    Write-Log 'done'
}
finally {
    # Off by default: a session is per-account and per-machine, and closing one
    # another job is using breaks that job.
    if ($sessionOpened -and $CloseSession -and $iloktool) {
        Write-Log 'closing the iLok Cloud session'
        & $iloktool cloud --close --account $env:PACE_ACCOUNT 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log 'session closed' }
        else { Write-Log 'WARNING: could not close the session. Close it from iLok License Manager.' }
    }
}
