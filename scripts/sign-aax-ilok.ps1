<#
.SYNOPSIS
    AAX signing on Windows with a physical iLok, as a HOST PROCESS.

.DESCRIPTION
    This runs on the win-ilok runner, which is deliberately NOT containerized
    and deliberately has NO COMPILER.

    Not containerized because a Windows container cannot see a USB device. There
    is no passthrough, no flag and no workaround — the machine holding the
    dongle signs as a host process, full stop.

    No compiler because this machine holds a signing credential. A build job
    that could run here would be a build job that could compromise the signing
    host, so the split is a security boundary, not a packaging detail.

    CREDENTIALS NEVER APPEAR IN ARGV. wraptool reads its account credentials
    from the environment, and this script uses that rather than
    --account/--password:

        PF_ACCOUNT_ID       <- PACE_ACCOUNT
        PF_ACCOUNT_PASSWORD <- PACE_PASSWORD

    An argument list is readable from the process table by any user on the
    machine; an environment is not. If iLok License Manager is already signed
    in, both may be omitted — wraptool finds the account itself.

    TWO WINDOWS-SPECIFIC RULES, both from PACE's AAX signing documentation:

    1. `wraptool sign` operates IN PLACE on Windows. --in and --out must name
       the same path. This script refuses a differing -OutputPath rather than
       silently producing something Pro Tools will reject.

    2. You must not sign a RENAMED copy of the bundle. Renaming the outer
       folder alone leaves the inner binary with a different name than its
       folder, which is a malformed plugin. Rename both, or neither.

    Parameters are -InputPath/-OutputPath and NOT -Input/-Output on purpose:
    $Input is an AUTOMATIC variable in PowerShell (the pipeline enumerator),
    and a parameter of that name binds to nothing and arrives silently empty.
    Do not "simplify" these names back.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    # 40-character SHA-1 thumbprint of a certificate in the Personal store.
    # On Windows --signid is the thumbprint, NOT the subject name.
    [string]$SignId = '',

    # Alternative to -SignId: a PKCS#12 file. Only possible for software-key
    # certificates issued before June 2023 and for private-trust certificates;
    # public-trust certificates are hardware-bound and cannot be exported.
    [string]$KeyFile = '',

    [string]$WcGuid = '',
    [string]$CustomerNumber = '',
    [string]$CustomerName = '',
    [string]$ProductName = '',

    [string]$OutputPath = '',

    # Path to signtool.exe. wraptool finds it in the default SDK locations when
    # this is omitted.
    [string]$SignTool = '',

    [switch]$SelfSigned,

    # SHA-2 is mandatory on modern Windows. Only turn this off for a product
    # that must support Windows versions old enough to need SHA-1.
    [switch]$Sha1Legacy,

    [switch]$DryRun,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Message) Write-Host "[sign-aax-ilok] $Message" }

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if (-not $SignId -and -not $KeyFile) {
    Write-Host 'error: on Windows you must give either -SignId (a certificate thumbprint' -ForegroundColor Red
    Write-Host '       in the Personal store) or -KeyFile (a PKCS#12 file).' -ForegroundColor Red
    Write-Host '       No certificate at all? Create one for testing with:' -ForegroundColor Red
    Write-Host '         .\make-signing-cert.ps1 -Subject "My Plugin Signing"' -ForegroundColor Red
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

# Rule 1 above, enforced rather than documented-and-hoped-for.
if ($OutputPath -and ($OutputPath -ne $InputPath)) {
    Write-Host 'error: on Windows wraptool sign operates IN PLACE — --in and --out must be' -ForegroundColor Red
    Write-Host '       the same path. You gave:' -ForegroundColor Red
    Write-Host "         -InputPath  $InputPath" -ForegroundColor Red
    Write-Host "         -OutputPath $OutputPath" -ForegroundColor Red
    Write-Host '       Copy the bundle to its final location FIRST, then sign it there.' -ForegroundColor Red
    Write-Host '       If you rename an .aaxplugin bundle, rename the inner binary too:' -ForegroundColor Red
    Write-Host '         MyPlugin.aaxplugin\Contents\x64\MyPlugin.aaxplugin' -ForegroundColor Red
    Write-Host '       A folder whose name differs from its inner binary is a malformed plugin.' -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# Find wraptool. The SDK installs it at a versioned path that is not on PATH.
# ---------------------------------------------------------------------------
function Find-Wraptool {
    if ($env:WRAPTOOL) {
        if (Test-Path $env:WRAPTOOL) { return $env:WRAPTOOL }
        Write-Host "error: WRAPTOOL is set to '$env:WRAPTOOL', which does not exist." -ForegroundColor Red
        return $null
    }
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
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if ($found) { return $found }
    }
    return $null
}

$wraptool = $null
if (-not $DryRun) {
    $wraptool = Find-Wraptool
    if (-not $wraptool) {
        Write-Host 'error: wraptool.exe was not found.' -ForegroundColor Red
        Write-Host '       Looked on PATH and under' -ForegroundColor Red
        Write-Host '         %ProgramFiles%\PACEAntiPiracy\Eden\Fusion\Versions\*\bin\wraptool.exe' -ForegroundColor Red
        Write-Host '       Install the PACE Fusion SDK on this host, or set WRAPTOOL to its path.' -ForegroundColor Red
        Write-Host '       This runner signs and does nothing else; it has no compiler by design.' -ForegroundColor Red
        exit 3
    }
    Write-Log "wraptool: $wraptool"
    & $wraptool --version 2>&1 | Select-Object -First 1 | ForEach-Object { Write-Log $_ }

    if (-not (Test-Path $InputPath)) {
        Write-Host "error: input does not exist: $InputPath" -ForegroundColor Red
        exit 2
    }

    # Check the certificate exists before spending a minute learning it doesn't.
    if ($SignId) {
        $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $SignId }
        if (-not $cert) {
            Write-Host "error: no certificate with thumbprint $SignId is in the Personal store." -ForegroundColor Red
            Write-Host '       Code-signing certificates available to this user:' -ForegroundColor Red
            Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.EnhancedKeyUsageList.FriendlyName -contains 'Code Signing' } |
                ForEach-Object { Write-Host "         $($_.Thumbprint)  $($_.Subject)" -ForegroundColor Red }
            Write-Host '       If the certificate is on a hardware token, attach the token first.' -ForegroundColor Red
            exit 3
        }
        Write-Log "certificate $SignId found: $($cert.Subject)"
        if ($cert.NotAfter -lt (Get-Date)) {
            Write-Host "error: that certificate expired on $($cert.NotAfter)." -ForegroundColor Red
            exit 3
        }
    }
    elseif (-not (Test-Path $KeyFile)) {
        Write-Host "error: -KeyFile does not exist: $KeyFile" -ForegroundColor Red
        exit 3
    }
}

# ---------------------------------------------------------------------------
# Build the argument list. Credentials are NOT in it.
# ---------------------------------------------------------------------------
$wraptoolArgs = @('sign', '--verbose', '--in', $InputPath)

if ($SignId)         { $wraptoolArgs += @('--signid', $SignId) }
if ($KeyFile)        { $wraptoolArgs += @('--keyfile', $KeyFile) }
if ($WcGuid)         { $wraptoolArgs += @('--wcguid', $WcGuid) }
if ($CustomerNumber) { $wraptoolArgs += @('--customernumber', $CustomerNumber) }
if ($CustomerName)   { $wraptoolArgs += @('--customername', $CustomerName) }
if ($ProductName)    { $wraptoolArgs += @('--productname', $ProductName) }
if ($SignTool)       { $wraptoolArgs += @('--signtool', $SignTool) }

# SHA-2 is mandatory on modern Windows. This is the documented way to tell the
# Windows SignTool to produce a compliant signature.
if (-not $Sha1Legacy) {
    $wraptoolArgs += @('--extrasigningoptions', 'digest_sha256')
} else {
    Write-Log 'WARNING: -Sha1Legacy given. SHA-1 is deprecated and modern Windows rejects it.'
}

if ($SelfSigned) {
    Write-Log 'self-signed mode:'
    Write-Log '  Windows will not trust this signature on any machine that has not been'
    Write-Log '  told to trust the certificate. SmartScreen will warn. The PACE signature'
    Write-Log '  is unaffected — Pro Tools checks that, not Authenticode.'
}

if ($DryRun) {
    $printable = ($wraptoolArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    Write-Host '[dry-run] $env:PF_ACCOUNT_ID=<PACE_ACCOUNT>; $env:PF_ACCOUNT_PASSWORD=<redacted>'
    Write-Host "[dry-run]   wraptool $printable"
    Write-Log 'dry run: inputs validated, nothing signed, no credentials on any command line'
    exit 0
}

Write-Log "signing $InputPath in place with the local iLok"

$previousId = $env:PF_ACCOUNT_ID
$previousPw = $env:PF_ACCOUNT_PASSWORD
try {
    if ($env:PACE_ACCOUNT)  { $env:PF_ACCOUNT_ID = $env:PACE_ACCOUNT }
    if ($env:PACE_PASSWORD) { $env:PF_ACCOUNT_PASSWORD = $env:PACE_PASSWORD }

    $signOutput = & $wraptool @wraptoolArgs 2>&1 | Tee-Object -Variable teed | Out-String
    $signExit = $LASTEXITCODE
}
finally {
    # The password does not outlive the call that needed it.
    $env:PF_ACCOUNT_ID = $previousId
    $env:PF_ACCOUNT_PASSWORD = $previousPw
}

$teed | ForEach-Object { Write-Host $_ }

if ($signExit -ne 0) {
    Write-Host ''
    Write-Host "error: wraptool sign failed. The message above is PACE's, verbatim." -ForegroundColor Red

    # PACE's failures are precise but the remedy is not in the message. Map the
    # ones a signing host actually hits to the exact next action.
    switch -Regex ($signOutput) {
        'CouldNotFindSignerCredentials' {
            Write-Host '  -> No connected iLok holds a code-signing certificate for this publisher.' -ForegroundColor Red
            Write-Host '     In iLok License Manager, right-click the iLok and choose Synchronize.' -ForegroundColor Red
            Write-Host "     The icon gains a 'seal' once the certificate is installed." -ForegroundColor Red
            break
        }
        'SigningCertExpired' {
            Write-Host '  -> The iLok code-signing certificate has expired. Connect ONLY the' -ForegroundColor Red
            Write-Host '     signing iLok and Synchronize it in iLok License Manager to renew.' -ForegroundColor Red
            break
        }
        'SigningCertWrongPublisherId' {
            Write-Host '  -> The certificate does not match the publisher you asked for. This' -ForegroundColor Red
            Write-Host '     happens when the account covers several publishers. Connect ONLY' -ForegroundColor Red
            Write-Host '     the signing iLok, Synchronize, and check -WcGuid.' -ForegroundColor Red
            break
        }
        'MissingFusionToolsLicense' {
            Write-Host '  -> The PACE Tools license authorizing wraptool is not reachable.' -ForegroundColor Red
            Write-Host '     Connect the iLok holding it, or activate it to this machine.' -ForegroundColor Red
            break
        }
        'InvalidPassword|must specify a password' {
            Write-Host '  -> PACE_ACCOUNT / PACE_PASSWORD were rejected or incomplete. They come' -ForegroundColor Red
            Write-Host '     from the OS keystore; re-enter them on the Credentials page.' -ForegroundColor Red
            break
        }
    }
    exit 4
}

Write-Log 'verifying the signature'
& $wraptool verify --verbose --in $InputPath
if ($LASTEXITCODE -ne 0) {
    Write-Host 'error: the signed bundle failed wraptool verify.' -ForegroundColor Red
    exit 4
}

Write-Log 'done'
