<#
.SYNOPSIS
    AAX signing via PACE Cloud 2 Cloud. No dongle anywhere.

.DESCRIPTION
    The Windows twin of scripts/sign-aax-cloud.sh, with identical behaviour.

    This mode signs INSIDE THE BUILD JOB, in the win-build container, because
    there is no physical device to be near:

      1. Open an iLok Cloud session on this machine.
      2. Run `wraptool sign` with --allowsigningservice appended.
      3. Close the session in a finally block, so a failed build can never leak
         an open session that counts against the account's activation limit.

    Confirm with PACE that your entitlement includes the cloud signing service
    before relying on this. --allowsigningservice is the documented flag, but the
    flag is only half the story: the ACCOUNT has to be entitled. If it is not,
    wraptool fails at sign time with a licensing error, which this script
    surfaces verbatim rather than swallowing.

    Credentials arrive in the ENVIRONMENT, never as arguments:
      PACE_ACCOUNT, PACE_PASSWORD
#>
# NOTE: the parameter is -InputPath, not -Input. $Input is a PowerShell
# AUTOMATIC variable (the pipeline enumerator); a parameter of that name is
# silently shadowed and always arrives empty. Do not "simplify" it back.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $InputPath,
    [Parameter(Mandatory = $false)] [string] $OutputPath,
    [Parameter(Mandatory = $false)] [string] $WcGuid,
    [Parameter(Mandatory = $false)] [string] $SignId,
    [Parameter(Mandatory = $false)] [switch] $DryRun,
    [Parameter(Mandatory = $false)] [switch] $Help
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
sign-aax-cloud.ps1 - sign an .aaxplugin using PACE Cloud 2 Cloud (no dongle).

Usage:
  sign-aax-cloud.ps1 -InputPath <bundle.aaxplugin> -WcGuid <guid> -SignId <id>
                     [-OutputPath <path>] [-DryRun] [-Help]

  -InputPath  The UNSIGNED .aaxplugin bundle.
  -WcGuid     PACE wrapping certificate GUID (signing.paceWcGuid).
  -SignId     PACE signing identifier (signing.paceSignId).
  -OutputPath Where to write the signed bundle. Defaults to signing in place.
  -DryRun     Print every command that would run, change nothing, and still
             validate that all required credentials are present.

Required environment (never passed as arguments):
  PACE_ACCOUNT, PACE_PASSWORD

Exit codes: 0 ok, 2 usage, 3 missing credential, 4 signing failure.
'@ | Write-Host
}

if ($Help) { Show-Usage; exit 0 }

function Write-Note { param([string] $Message) Write-Host "[sign-aax-cloud] $Message" }

foreach ($pair in @(@('-InputPath', $InputPath), @('-WcGuid', $WcGuid), @('-SignId', $SignId))) {
    if ([string]::IsNullOrWhiteSpace($pair[1])) {
        Write-Host "error: $($pair[0]) is required" -ForegroundColor Red
        Show-Usage
        exit 2
    }
}

# --- credential check first, so a missing secret fails in a second ----------
$missing = @()
if ([string]::IsNullOrWhiteSpace($env:PACE_ACCOUNT))  { $missing += 'PACE_ACCOUNT' }
if ([string]::IsNullOrWhiteSpace($env:PACE_PASSWORD)) { $missing += 'PACE_PASSWORD' }

if ($missing.Count -gt 0) {
    Write-Host 'error: cannot sign - the following required credentials are absent:' -ForegroundColor Red
    foreach ($item in $missing) { Write-Host "  - $item" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'They live in Windows Credential Manager (paceAccount / pacePassword) and are'
    Write-Host 'injected as environment variables at job time. Never put them in forge.json.'
    exit 3
}

if (-not $DryRun) {
    if (-not (Get-Command wraptool -ErrorAction SilentlyContinue)) {
        Write-Host 'error: wraptool is not on PATH. Install PACE Eden tools.' -ForegroundColor Red
        exit 3
    }
    if (-not (Test-Path $InputPath)) {
        Write-Host "error: input does not exist: $InputPath" -ForegroundColor Red
        exit 2
    }
}

Write-Note 'credentials present'

$target = if ($Output) { $OutputPath } else { $InputPath }
$sessionOpened = $false

try {
    Write-Note 'opening an iLok Cloud session'
    if ($DryRun) {
        Write-Host '[dry-run] wraptool activate --account <PACE_ACCOUNT> --password <redacted> --cloud'
    }
    else {
        & wraptool activate --account $env:PACE_ACCOUNT --password $env:PACE_PASSWORD --cloud
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'error: could not open an iLok Cloud session.' -ForegroundColor Red
            Write-Host '       Confirm with PACE that this account is entitled to iLok Cloud (Cloud 2 Cloud).'
            exit 4
        }
        $sessionOpened = $true
    }

    Write-Note "signing $InputPath -> $target"
    if ($DryRun) {
        Write-Host "[dry-run] wraptool sign --verbose --account <PACE_ACCOUNT> --password <redacted> --wcguid $WcGuid --signid $SignId --in $InputPath --out $target --allowsigningservice"
        Write-Note 'dry run: credentials validated, no changes made'
    }
    else {
        # --allowsigningservice is what makes cloud signing work; without it
        # wraptool expects a local activation.
        & wraptool sign --verbose `
            --account $env:PACE_ACCOUNT `
            --password $env:PACE_PASSWORD `
            --wcguid $WcGuid `
            --signid $SignId `
            --in $InputPath `
            --out $target `
            --allowsigningservice
        if ($LASTEXITCODE -ne 0) {
            Write-Host "error: wraptool sign failed. The message above is PACE's, reproduced verbatim." -ForegroundColor Red
            Write-Host '       A licensing error here usually means the account is not entitled to the'
            Write-Host '       cloud signing service, which --allowsigningservice cannot grant on its own.'
            exit 4
        }

        Write-Note 'verifying the signature'
        & wraptool verify --verbose --in $target
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'error: the signed bundle failed verification' -ForegroundColor Red
            exit 4
        }
    }
}
finally {
    # The session is closed whether signing succeeded, failed, or threw. A leaked
    # session counts against the account's activation limit until it expires.
    if ($sessionOpened) {
        Write-Note 'closing the iLok Cloud session'
        & wraptool deactivate --account $env:PACE_ACCOUNT --password $env:PACE_PASSWORD 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Note 'session closed' }
        else { Write-Note 'WARNING: could not close the iLok Cloud session; it may count against your activation limit until it expires' }
    }
}

Write-Note 'done'
