[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Version,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/\s]+/[^/\s]+$')]
    [string]$Repository,
    [string]$ReleaseTag = "v$Version",
    [string]$OutputDirectory = "dist",
    [string]$ReleaseNotesPath
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root $OutputDirectory
$assetName = "Lithe-$Version-windows-x64.nsis.zip"
$asset = Join-Path $output $assetName
$signaturePath = "$asset.sig"

if (-not (Test-Path -LiteralPath $asset -PathType Leaf)) {
    throw "Windows updater bundle does not exist: $asset"
}
if (-not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) {
    throw "Windows updater signature does not exist: $signaturePath"
}

$signature = (Get-Content -LiteralPath $signaturePath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($signature)) {
    throw "Windows updater signature is empty: $signaturePath"
}

$notes = "Lithe $Version for Windows."
if (-not [string]::IsNullOrWhiteSpace($ReleaseNotesPath)) {
    $resolvedNotesPath = if ([System.IO.Path]::IsPathRooted($ReleaseNotesPath)) {
        $ReleaseNotesPath
    } else {
        Join-Path $root $ReleaseNotesPath
    }
    if (Test-Path -LiteralPath $resolvedNotesPath -PathType Leaf) {
        $notes = (Get-Content -LiteralPath $resolvedNotesPath -Raw).Trim()
    }
}

$encodedTag = [System.Uri]::EscapeDataString($ReleaseTag)
$encodedAssetName = [System.Uri]::EscapeDataString($assetName)
$downloadURL = "https://github.com/$Repository/releases/download/$encodedTag/$encodedAssetName"
$manifest = [ordered]@{
    version = $Version
    notes = $notes
    pub_date = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    platforms = [ordered]@{
        "windows-x86_64" = [ordered]@{
            signature = $signature
            url = $downloadURL
        }
    }
}

New-Item -ItemType Directory -Force -Path $output | Out-Null
$manifestPath = Join-Path $output "latest.json"
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Output "Windows updater manifest created: $manifestPath"
