<#
.SYNOPSIS
    AAX signing with a physical iLok dongle, as a HOST PROCESS.

.DESCRIPTION
    The Windows twin of scripts/sign-aax-ilok.sh.

    This runs on the win-ilok runner, which is deliberately NOT containerized and
    deliberately has NO COMPILER.

    Not containerized because A WINDOWS CONTAINER CANNOT SEE A USB DEVICE. There
    is no passthrough, no flag, no workaround and no plan for one. This is not a
    limitation Runner Forge can engineer around.

    No compiler because this machine holds a signing credential. A build job that
    could run here would be a build job that could compromise the signing host,
    so the split is a security boundary rather than a packaging detail.

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
sign-aax-ilok.ps1 - sign an .aaxplugin using a physical iLok dongle on this host.

Usage:
  sign-aax-ilok.ps1 -InputPath <bundle.aaxplugin> -WcGuid <guid> -SignId <id>
                    [-OutputPath <path>] [-DryRun] [-Help]

  -InputPath  The UNSIGNED .aaxplugin bundle, downloaded from the build job.
  -WcGuid     PACE wrapping certificate GUID (signing.paceWcGuid).
  -SignId     PACE signing identifier (signing.paceSignId).
  -OutputPath Where to write the signed bundle. Defaults to signing in place.
  -DryRun     Print every command that would run, change nothing, and still
             validate that all required credentials and the dongle are present.

Required environment (never passed as arguments):
  PACE_ACCOUNT, PACE_PASSWORD

Exit codes: 0 ok, 2 usage, 3 missing credential or dongle, 4 signing failure.
'@ | Write-Host
}

if ($Help) { Show-Usage; exit 0 }

function Write-Note { param([string] $Message) Write-Host "[sign-aax-ilok] $Message" }

foreach ($pair in @(@('-InputPath', $InputPath), @('-WcGuid', $WcGuid), @('-SignId', $SignId))) {
    if ([string]::IsNullOrWhiteSpace($pair[1])) {
        Write-Host "error: $($pair[0]) is required" -ForegroundColor Red
        Show-Usage
        exit 2
    }
}

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
        Write-Host 'error: wraptool.exe is not on PATH. Install PACE Eden tools on this host.' -ForegroundColor Red
        Write-Host '       This runner signs and does nothing else; it has no compiler by design.'
        exit 3
    }

    # A dongle that is not plugged in is the most common failure here, and
    # wraptool's own error for it is unhelpfully generic. Check it up front.
    $tokens = & wraptool list-tokens 2>&1 | Out-String
    if ($tokens -notmatch 'ilok') {
        Write-Host 'error: no iLok token is visible to wraptool on this host.' -ForegroundColor Red
        Write-Host "       Plug the dongle in, or switch signing.mode to 'cloud'."
        Write-Host '       Note that a Windows container can NEVER see a USB device: this runner is'
        Write-Host '       a host process precisely so that the dongle is reachable at all.'
        exit 3
    }

    if (-not (Test-Path $InputPath)) {
        Write-Host "error: input does not exist: $InputPath" -ForegroundColor Red
        exit 2
    }
}

$target = if ($Output) { $OutputPath } else { $InputPath }

Write-Note "signing $InputPath -> $target using the local dongle"

if ($DryRun) {
    Write-Host "[dry-run] wraptool sign --verbose --account <PACE_ACCOUNT> --password <redacted> --wcguid $WcGuid --signid $SignId --in $InputPath --out $target"
    Write-Note 'dry run: credentials validated, no changes made'
    exit 0
}

# No --allowsigningservice here: this is a local activation on a physical token.
& wraptool sign --verbose `
    --account $env:PACE_ACCOUNT `
    --password $env:PACE_PASSWORD `
    --wcguid $WcGuid `
    --signid $SignId `
    --in $InputPath `
    --out $target

if ($LASTEXITCODE -ne 0) {
    Write-Host "error: wraptool sign failed. The message above is PACE's, reproduced verbatim." -ForegroundColor Red
    exit 4
}

Write-Note 'verifying the signature'
& wraptool verify --verbose --in $target
if ($LASTEXITCODE -ne 0) {
    Write-Host 'error: the signed bundle failed verification' -ForegroundColor Red
    exit 4
}

Write-Note 'done'
