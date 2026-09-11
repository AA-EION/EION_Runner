<#
.SYNOPSIS
    Create a SELF-SIGNED code-signing certificate on Windows.

.DESCRIPTION
    This exists for one situation: you want to sign an AAX plugin with wraptool
    and you do not (yet) have an Authenticode certificate from a Microsoft-
    approved certificate authority. PACE's own guidance is explicit that this is
    a LEARNING AND TESTING step, not a shipping one — see docs/SIGNING.md, which
    spells out exactly what a self-signed certificate can and cannot do for a
    plugin you hand to someone else.

    The New-SelfSignedCertificate call below is the one PACE's Signing Resources
    page publishes, with the validity period and store made configurable.

    WHERE THE PRIVATE KEY GOES: into the Windows certificate store, and nowhere
    else. It is NEVER written next to the plugin and NEVER shipped inside the
    bundle. A signing key that travels with the artifact is not a signing key,
    it is a published key — anyone holding it can sign anything as you.

    Parameters are named -Subject/-OutputPfx and NOT -Input/-Output on purpose:
    $Input is an AUTOMATIC variable in PowerShell (the pipeline enumerator), and
    a parameter of that name binds to nothing and arrives silently empty.

.EXAMPLE
    .\make-signing-cert.ps1 -Subject "My Plugin Signing"

.EXAMPLE
    $env:PFX_PASSWORD = '...'
    .\make-signing-cert.ps1 -Subject "My Plugin Signing" -OutputPfx C:\keys\signing.pfx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Subject,

    # CurrentUser needs no elevation. LocalMachine makes the certificate
    # available to every user and to services, and requires an elevated prompt.
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$StoreLocation = 'CurrentUser',

    [int]$Years = 3,

    [string]$OutputPfx = '',

    [switch]$Force,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Message) Write-Host "[make-signing-cert] $Message" }

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'error: this is the Windows generator. On macOS use scripts/make-signing-cert.sh.' -ForegroundColor Red
    exit 3
}

$storePath = "Cert:\$StoreLocation\My"

# A subject that already has a certificate is not silently duplicated: two
# code-signing certificates with the same subject make the thumbprint choice
# ambiguous for a human reading the list, which is how the wrong one gets used.
$existing = @(Get-ChildItem $storePath |
    Where-Object { $_.Subject -eq "CN=$Subject" -and $_.EnhancedKeyUsageList.FriendlyName -contains 'Code Signing' })

if ($existing.Count -gt 0) {
    if (-not $Force) {
        Write-Host "error: a code-signing certificate for CN=$Subject already exists in $storePath." -ForegroundColor Red
        Write-Host '       Thumbprint(s):' -ForegroundColor Red
        $existing | ForEach-Object { Write-Host "         $($_.Thumbprint)" -ForegroundColor Red }
        Write-Host '       Pass -Force to replace it, or choose a different -Subject.' -ForegroundColor Red
        exit 3
    }
    Write-Log "-Force given: removing $($existing.Count) existing certificate(s) for CN=$Subject"
    $existing | ForEach-Object { Remove-Item -Path "$storePath\$($_.Thumbprint)" -Force }
}

Write-Log "generating a code-signing certificate for CN=$Subject in $storePath, valid $Years year(s)"

# This is PACE's published invocation. KeyExportPolicy Exportable is what makes
# the -OutputPfx backup below possible at all; drop it and the key can never
# leave this machine, which is more secure and less recoverable.
$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject "CN=$Subject" `
    -FriendlyName $Subject `
    -CertStoreLocation $storePath `
    -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' `
    -KeyExportPolicy Exportable `
    -NotAfter (Get-Date).AddYears($Years)

if (-not $cert) {
    Write-Host 'error: New-SelfSignedCertificate returned nothing' -ForegroundColor Red
    exit 4
}

# Proof rather than assumption. A certificate without the Code Signing EKU is
# rejected by signtool later, with a much less obvious message than this one.
$eku = $cert.EnhancedKeyUsageList | ForEach-Object { $_.FriendlyName }
if ($eku -notcontains 'Code Signing') {
    Write-Host "error: the generated certificate has no Code Signing EKU (found: $($eku -join ', '))" -ForegroundColor Red
    exit 4
}
Write-Log 'verified: Code Signing EKU present'

if ($OutputPfx) {
    if (-not $env:PFX_PASSWORD) {
        Write-Host 'error: -OutputPfx needs PFX_PASSWORD in the environment.' -ForegroundColor Red
        Write-Host '       It is read from the environment and never from the argument list,' -ForegroundColor Red
        Write-Host '       because an argument list is readable by any user on this machine.' -ForegroundColor Red
        exit 2
    }

    $securePassword = ConvertTo-SecureString -String $env:PFX_PASSWORD -AsPlainText -Force
    $directory = Split-Path -Parent $OutputPfx
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    Export-PfxCertificate -Cert "$storePath\$($cert.Thumbprint)" `
        -FilePath $OutputPfx -Password $securePassword | Out-Null

    Write-Log "PFX backup written to $OutputPfx"
    Write-Log 'KEEP IT OUT OF THE PLUGIN AND OUT OF GIT. It contains the private key.'
}

Write-Host ''
Write-Log 'done. The signing certificate is:'
Write-Host ''
Write-Host ('  Thumbprint                                Subject')
Write-Host ('  ----------                                -------')
Write-Host ("  $($cert.Thumbprint)  $($cert.Subject)")
Write-Host ''
Write-Log "Pass it to wraptool as:  --signid $($cert.Thumbprint)"
Write-Log 'On Windows --signid takes the 40-character thumbprint, not the subject name.'
