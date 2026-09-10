<#
.SYNOPSIS
    Mint a just-in-time runner configuration.

.DESCRIPTION
    The Windows twin of scripts/jitconfig.sh, with identical behaviour.

    This is the only way a Runner Forge runner ever registers. There is no
    long-lived registration token anywhere in this product, and no config.cmd
    step: a JIT config IS the configuration, and it is valid for exactly one job.

      1. Sign a JWT with the GitHub App private key (RS256, iat -60s, exp +9min).
         The 60-second backdate absorbs clock skew, which GitHub otherwise
         rejects as a token issued in the future.
      2. POST /app/installations/{id}/access_tokens  -> an installation token.
      3. POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig
         -> a base64 blob that is the runner's whole configuration.

    The blob is written to STDOUT and nowhere else, so the caller can pipe it
    straight into `docker run -i` without it ever touching disk. Everything
    printed for humans goes to the information/error streams instead.

    The private key never appears in an argument — only the PATH to it does.

.EXAMPLE
    .\jitconfig.ps1 -Owner o -Repo r -AppId 1 -InstallationId 2 `
        -KeyFile C:\keys\app.pem -ClassId win-build `
        -Labels 'self-hosted,windows,x64,container,forge' |
      docker run -i --rm runnerforge/win-build:1.0.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string] $Owner,
    [Parameter(Mandatory = $true)]  [string] $Repo,
    [Parameter(Mandatory = $true)]  [string] $AppId,
    [Parameter(Mandatory = $true)]  [string] $InstallationId,
    [Parameter(Mandatory = $true)]  [string] $ClassId,
    [Parameter(Mandatory = $true)]  [string] $Labels,
    [Parameter(Mandatory = $false)] [string] $KeyFile,
    [Parameter(Mandatory = $false)] [string] $RunnerName,
    [Parameter(Mandatory = $false)] [int]    $RunnerGroupId = 1,
    [Parameter(Mandatory = $false)] [string] $ApiUrl = 'https://api.github.com'
)

$ErrorActionPreference = 'Stop'

function Write-Note { param([string] $Message) Write-Information "[jitconfig] $Message" -InformationAction Continue }

function ConvertTo-Base64Url {
    param([Parameter(Mandatory = $true)] [byte[]] $Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# ---------------------------------------------------------------------------
# The private key. Read from a file path or from stdin; never from an argument,
# because arguments are visible in the process list.
# ---------------------------------------------------------------------------
if ($KeyFile) {
    if (-not (Test-Path $KeyFile)) { throw "Cannot read key file: $KeyFile" }
    $privateKeyPem = Get-Content -Path $KeyFile -Raw
}
elseif ([Console]::IsInputRedirected) {
    $privateKeyPem = [Console]::In.ReadToEnd()
}
else {
    throw 'No -KeyFile given and stdin is a terminal. Supply the GitHub App private key.'
}

if ($privateKeyPem -notmatch '-----BEGIN .*PRIVATE KEY-----') {
    throw 'The supplied key is not a PEM private key.'
}

# ---------------------------------------------------------------------------
# Runner name: forge-<classId>-<shorthost>-<8 hex>
# ---------------------------------------------------------------------------
if (-not $RunnerName) {
    $shortHost = ([System.Net.Dns]::GetHostName() -replace '[^A-Za-z0-9-]', '')
    if ($shortHost.Length -gt 16) { $shortHost = $shortHost.Substring(0, 16) }
    $suffixBytes = [byte[]]::new(4)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($suffixBytes)
    $suffix = ($suffixBytes | ForEach-Object { $_.ToString('x2') }) -join ''
    $RunnerName = "forge-$ClassId-$shortHost-$suffix"
}
Write-Note "runner name: $RunnerName"

# ---------------------------------------------------------------------------
# 1. The app JWT.
# ---------------------------------------------------------------------------
$rsa = [System.Security.Cryptography.RSA]::Create()
try {
    $rsa.ImportFromPem($privateKeyPem.ToCharArray())
}
catch {
    throw "Failed to import the private key: $($_.Exception.Message)"
}
finally {
    $privateKeyPem = $null
}

$now     = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$header  = '{"alg":"RS256","typ":"JWT"}'
# iat is backdated 60s for clock skew; exp is 9 minutes, inside GitHub's 10
# minute maximum.
$payload = "{`"iat`":$($now - 60),`"exp`":$($now + 540),`"iss`":`"$AppId`"}"

$signingInput = '{0}.{1}' -f
    (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))),
    (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload)))

$signature = $rsa.SignData(
    [Text.Encoding]::UTF8.GetBytes($signingInput),
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

$jwt = '{0}.{1}' -f $signingInput, (ConvertTo-Base64Url $signature)
$rsa.Dispose()

# ---------------------------------------------------------------------------
# GitHub calls. The error body is surfaced verbatim: guessing what a 401 means
# wastes far more time than reading what GitHub actually said.
# ---------------------------------------------------------------------------
function Invoke-GitHubPost {
    param(
        [Parameter(Mandatory = $true)] [string] $Uri,
        [Parameter(Mandatory = $true)] [string] $Token,
        [Parameter(Mandatory = $false)] $Body,
        [Parameter(Mandatory = $true)] [string] $What
    )

    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'RunnerForge'
    }

    try {
        if ($null -ne $Body) {
            return Invoke-RestMethod -Method Post -Uri $Uri -Headers $headers `
                -Body ($Body | ConvertTo-Json -Compress -Depth 5) -ContentType 'application/json'
        }
        return Invoke-RestMethod -Method Post -Uri $Uri -Headers $headers
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        throw "Could not $What. GitHub said:`n$detail"
    }
}

# 2. The installation token.
$tokenResponse = Invoke-GitHubPost `
    -Uri "$ApiUrl/app/installations/$InstallationId/access_tokens" `
    -Token $jwt -What 'mint an installation token'
$jwt = $null

$installationToken = $tokenResponse.token
if (-not $installationToken) { throw 'The token response contained no token.' }

# 3. The JIT config.
$labelList = $Labels -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($labelList.Count -eq 0) { throw 'No labels supplied. A runner with no labels can never be targeted by a workflow.' }

$jitResponse = Invoke-GitHubPost `
    -Uri "$ApiUrl/repos/$Owner/$Repo/actions/runners/generate-jitconfig" `
    -Token $installationToken `
    -Body @{ name = $RunnerName; runner_group_id = $RunnerGroupId; labels = @($labelList) } `
    -What 'generate a JIT config'
$installationToken = $null

$blob = $jitResponse.encoded_jit_config
if (-not $blob) { throw 'The response contained no encoded_jit_config.' }

Write-Note "minted a JIT config for $RunnerName ($($blob.Length) bytes)"

# stdout carries the blob and nothing else.
Write-Output $blob
