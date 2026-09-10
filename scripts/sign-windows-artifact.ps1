<#
.SYNOPSIS
    Authenticode-sign Windows binaries and installers with Azure Trusted Signing.

.DESCRIPTION
    Independent of AAX signing. This signs the .exe, .dll and .vst3 binaries and
    the Inno Setup installer.

    Azure Trusted Signing (formerly Azure Code Signing / Azure Artifact Signing)
    keeps the private key in a cloud HSM. There is no certificate file on disk
    and no dongle, which is exactly why this CAN run inside the win-build
    container while AAX iLok signing cannot.

    Credentials arrive in the ENVIRONMENT, never as arguments:
      AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID

.NOTES
    Set signing.windows.provider to "none" to skip Authenticode entirely. The
    artifacts are still produced, just unsigned, and the workflow says so rather
    than pretending.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string]   $ArtifactDir,
    [Parameter(Mandatory = $false)] [string[]] $Include = @('*.exe', '*.dll', '*.vst3'),
    [Parameter(Mandatory = $false)] [string]   $Endpoint,
    [Parameter(Mandatory = $false)] [string]   $Account,
    [Parameter(Mandatory = $false)] [string]   $Profile,
    [Parameter(Mandatory = $false)] [string]   $TimestampUrl = 'http://timestamp.acs.microsoft.com',
    [Parameter(Mandatory = $false)] [switch]   $DryRun,
    [Parameter(Mandatory = $false)] [switch]   $Help
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
sign-windows-artifact.ps1 - Authenticode signing via Azure Trusted Signing.

Usage:
  sign-windows-artifact.ps1 -ArtifactDir <dir> -Endpoint <url> -Account <name>
                            -Profile <name> [-Include <patterns>]
                            [-TimestampUrl <url>] [-DryRun] [-Help]

  -ArtifactDir   Directory to sign, searched recursively.
  -Endpoint      Trusted Signing endpoint, e.g. https://eus.codesigning.azure.net
  -Account       Trusted Signing account name (signing.windows.azureAccount).
  -Profile       Certificate profile name (signing.windows.azureProfile).
  -Include       File patterns to sign. Defaults to *.exe, *.dll, *.vst3.
  -DryRun        List what would be signed, change nothing, and still validate
                 that all required credentials are present.

Required environment (never passed as arguments):
  AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID

Exit codes: 0 ok, 2 usage, 3 missing credential or tool, 4 signing failure.
'@ | Write-Host
}

if ($Help) { Show-Usage; exit 0 }

function Write-Note { param([string] $Message) Write-Host "[sign-windows] $Message" }

foreach ($pair in @(@('-ArtifactDir', $ArtifactDir), @('-Endpoint', $Endpoint),
                    @('-Account', $Account), @('-Profile', $Profile))) {
    if ([string]::IsNullOrWhiteSpace($pair[1])) {
        Write-Host "error: $($pair[0]) is required" -ForegroundColor Red
        Show-Usage
        exit 2
    }
}

# --- credential check first -------------------------------------------------
$missing = @()
if ([string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID))     { $missing += 'AZURE_CLIENT_ID' }
if ([string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_SECRET)) { $missing += 'AZURE_CLIENT_SECRET' }
if ([string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID))     { $missing += 'AZURE_TENANT_ID' }

if ($missing.Count -gt 0) {
    Write-Host 'error: cannot sign - the following required credentials are absent:' -ForegroundColor Red
    foreach ($item in $missing) { Write-Host "  - $item" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'They live in Windows Credential Manager (azureClientId / azureClientSecret /'
    Write-Host 'azureTenantId) and are injected as environment variables at job time. Never'
    Write-Host 'put them in forge.json.'
    Write-Host ''
    Write-Host 'Set signing.windows.provider to "none" to skip Authenticode signing entirely;'
    Write-Host 'the artifacts are still produced, just unsigned.'
    exit 3
}

Write-Note 'credentials present'

if (-not $DryRun -and -not (Test-Path $ArtifactDir)) {
    Write-Host "error: artifact dir does not exist: $ArtifactDir" -ForegroundColor Red
    exit 2
}

# --- find the signing tool --------------------------------------------------
# Trusted Signing is driven by signtool with the Azure dlib, or by the
# `Invoke-TrustedSigning` module. signtool is what ships in the Windows SDK that
# the image already has, so it is the primary path.
$signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue)?.Source
if (-not $signtool) {
    $candidates = @(Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin" `
                        -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -match 'x64' } |
                    Sort-Object FullName -Descending)
    if ($candidates.Count -gt 0) { $signtool = $candidates[0].FullName }
}

if (-not $signtool -and -not $DryRun) {
    Write-Host 'error: signtool.exe not found. It ships with the Windows SDK, which the' -ForegroundColor Red
    Write-Host '       win-build image installs; this script does not download tooling at job time.'
    exit 3
}

Write-Note "signtool: $(if ($signtool) { $signtool } else { '(not resolved; dry run)' })"

# --- the dlib metadata ------------------------------------------------------
# signtool needs a small JSON describing the Trusted Signing account. It holds
# NO SECRET - only endpoint, account and profile names. The actual credentials
# are read by the dlib from the environment.
$metadataDir = Join-Path ([System.IO.Path]::GetTempPath()) "runnerforge-signing-$PID"
$metadataPath = Join-Path $metadataDir 'metadata.json'

try {
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $metadataDir | Out-Null
        @{
            Endpoint               = $Endpoint
            CodeSigningAccountName = $Account
            CertificateProfileName = $Profile
        } | ConvertTo-Json | Set-Content -Path $metadataPath -Encoding utf8
    }

    $files = @()
    if (Test-Path $ArtifactDir) {
        foreach ($pattern in $Include) {
            $files += @(Get-ChildItem -Path $ArtifactDir -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue)
        }
    }
    $files = @($files | Sort-Object -Property FullName -Unique)

    if ($files.Count -eq 0) {
        # Not an error in dry run, but a real run that signs nothing almost
        # certainly means the wrong directory was passed.
        if ($DryRun) {
            Write-Note 'dry run: no matching files found (this is fine if the build has not run yet)'
            Write-Note 'dry run: credentials validated, no changes made'
            exit 0
        }
        Write-Host "error: no files matching $($Include -join ', ') under $ArtifactDir" -ForegroundColor Red
        Write-Host '       Signing nothing is almost always the wrong directory rather than an empty build.'
        exit 2
    }

    Write-Note "signing $($files.Count) file(s)"

    foreach ($file in $files) {
        Write-Note "  $($file.FullName)"
        if ($DryRun) {
            Write-Host "[dry-run] signtool sign /v /debug /fd SHA256 /tr $TimestampUrl /td SHA256 /dlib Azure.CodeSigning.Dlib.dll /dmdf <metadata> `"$($file.FullName)`""
            continue
        }

        & $signtool sign /v /debug /fd SHA256 `
            /tr $TimestampUrl /td SHA256 `
            /dlib 'Azure.CodeSigning.Dlib.dll' `
            /dmdf $metadataPath `
            $file.FullName

        if ($LASTEXITCODE -ne 0) {
            Write-Host "error: signtool failed for $($file.FullName) with exit code $LASTEXITCODE" -ForegroundColor Red
            exit 4
        }
    }

    if ($DryRun) {
        Write-Note 'dry run: credentials validated, no changes made'
        exit 0
    }

    # Verify rather than assume. A signature that does not verify is worse than
    # no signature: it looks done.
    Write-Note 'verifying signatures'
    foreach ($file in $files) {
        & $signtool verify /pa /v $file.FullName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "error: signature verification failed for $($file.FullName)" -ForegroundColor Red
            exit 4
        }
    }
    Write-Note "all $($files.Count) signature(s) verified"
}
finally {
    # The metadata holds no secret, but leaving temp files behind is how a work
    # directory slowly fills up.
    if (Test-Path $metadataDir) { Remove-Item -Recurse -Force $metadataDir -ErrorAction SilentlyContinue }
}

Write-Note 'done'
