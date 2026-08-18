[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$Version = "0.0.0",
    [string]$OutputDirectory = "dist",
    [string]$CertificateThumbprint = $env:LITHE_WINDOWS_CERTIFICATE_THUMBPRINT,
    [string]$TimestampServer = $env:LITHE_WINDOWS_TIMESTAMP_SERVER,
    [switch]$RequireAuthenticodeSignature
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$windowsApp = Join-Path $root "windows/tauri"
$output = Join-Path $root $OutputDirectory
$versionConfig = Join-Path $env:RUNNER_TEMP "lithe-tauri-version.json"

& (Join-Path $root "scripts/prepare-jdtls.ps1") | Out-Null
@{ version = $Version } | ConvertTo-Json | Set-Content -Encoding utf8 $versionConfig
Set-Location $windowsApp
& bun install --frozen-lockfile
if ($LASTEXITCODE -ne 0) { throw "Windows frontend dependency installation failed" }

$tauriArgs = @(
    "tauri", "build",
    "--config", "src-tauri/tauri.windows.conf.json",
    "--config", $versionConfig,
    "--bundles", "nsis"
)
if ($Configuration -eq "Debug") { $tauriArgs += "--debug" }
& bunx @tauriArgs
if ($LASTEXITCODE -ne 0) { throw "Tauri NSIS packaging failed" }

$bundleDirectory = Join-Path $windowsApp "src-tauri/target/release/bundle/nsis"
if ($Configuration -eq "Debug") {
    $bundleDirectory = Join-Path $windowsApp "src-tauri/target/debug/bundle/nsis"
}
$bundle = Get-ChildItem -LiteralPath $bundleDirectory -Filter "*.exe" -File |
    Select-Object -First 1
if ($null -eq $bundle) { throw "Tauri NSIS installer was not found in $bundleDirectory" }

New-Item -ItemType Directory -Force -Path $output | Out-Null
$installer = Join-Path $output "Lithe-$Version-windows-x64.exe"
Copy-Item -LiteralPath $bundle.FullName -Destination $installer -Force

if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    $certificate = Get-ChildItem -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint" `
        -ErrorAction SilentlyContinue
    if ($null -eq $certificate) {
        throw "The requested Authenticode certificate is not installed: $CertificateThumbprint"
    }
    $signatureArgs = @{
        FilePath = $installer
        Certificate = $certificate
        HashAlgorithm = "SHA256"
    }
    if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
        $signatureArgs.TimestampServer = $TimestampServer
    }
    $signature = Set-AuthenticodeSignature @signatureArgs
    if ($signature.Status -ne "Valid") {
        throw "Authenticode signing failed: $($signature.Status)"
    }
} elseif ($RequireAuthenticodeSignature) {
    throw "Authenticode signing is required but no certificate thumbprint was configured."
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
"$hash  $(Split-Path -Leaf $installer)" | Set-Content -Encoding ascii "$installer.sha256"
Write-Output "Windows installer created: $installer"
