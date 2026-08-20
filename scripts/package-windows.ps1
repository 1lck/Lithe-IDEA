[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$Version = "0.0.0",
    [string]$OutputDirectory = "dist",
    [string]$CertificateThumbprint = $env:LITHE_WINDOWS_CERTIFICATE_THUMBPRINT,
    [string]$TimestampServer = $env:LITHE_WINDOWS_TIMESTAMP_SERVER,
    [switch]$RequireAuthenticodeSignature,
    [string]$UpdaterPublicKey = $env:LITHE_UPDATER_PUBLIC_KEY,
    [string]$UpdaterEndpoint = $env:LITHE_UPDATER_ENDPOINT,
    [switch]$RequireUpdaterArtifacts
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$windowsApp = Join-Path $root "windows/tauri"
$output = Join-Path $root $OutputDirectory
$taskTempRoot = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetTempPath()
} else {
    $env:RUNNER_TEMP
}
$versionConfig = Join-Path $taskTempRoot "lithe-tauri-version.json"

& (Join-Path $root "scripts/prepare-jdtls.ps1") | Out-Null

$versionOverrides = @{
    version = $Version
    bundle = @{}
}
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    $windowsSigning = @{
        certificateThumbprint = $CertificateThumbprint
        digestAlgorithm = "sha256"
    }
    if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
        $windowsSigning.timestampUrl = $TimestampServer
    }
    $versionOverrides.bundle.windows = $windowsSigning
} elseif ($RequireAuthenticodeSignature) {
    throw "Authenticode signing is required but no certificate thumbprint was configured."
}

if ($RequireUpdaterArtifacts) {
    if ([string]::IsNullOrWhiteSpace($env:TAURI_SIGNING_PRIVATE_KEY)) {
        throw "Tauri updater signing is required but TAURI_SIGNING_PRIVATE_KEY is not configured."
    }
    if ([string]::IsNullOrWhiteSpace($UpdaterPublicKey)) {
        throw "Tauri updater signing is required but LITHE_UPDATER_PUBLIC_KEY is not configured."
    }
    if ([string]::IsNullOrWhiteSpace($UpdaterEndpoint)) {
        throw "Tauri updater signing is required but LITHE_UPDATER_ENDPOINT is not configured."
    }

    $versionOverrides.bundle.createUpdaterArtifacts = $true
    $versionOverrides.plugins = @{
        updater = @{
            pubkey = $UpdaterPublicKey
            endpoints = @($UpdaterEndpoint)
        }
    }
}

$versionOverrides | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $versionConfig
Set-Location $windowsApp

function Add-DirectoryToPath([string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $existing = $env:Path -split ";" | Where-Object { $_ -ne "" }
    if ($existing -contains $Directory) { return }
    $env:Path = "$Directory;" + $env:Path
}

$cargoHome = if (-not [string]::IsNullOrWhiteSpace($env:CARGO_HOME)) {
    $env:CARGO_HOME
} else {
    Join-Path $env:USERPROFILE ".cargo"
}
Add-DirectoryToPath (Join-Path $cargoHome "bin")
$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
if ($null -ne $nodeCommand) {
    Add-DirectoryToPath (Split-Path -Parent $nodeCommand.Source)
}

& bun install --frozen-lockfile
if ($LASTEXITCODE -ne 0) { throw "Windows frontend dependency installation failed" }

$tauriArgs = @(
    "tauri",
    "--",
    "build",
    "--config", "src-tauri/tauri.windows.conf.json",
    "--config", "src-tauri/tauri.jdtls.conf.json",
    "--config", $versionConfig,
    "--bundles", "nsis"
)
if ($Configuration -eq "Debug") { $tauriArgs += "--debug" }
& bun run @tauriArgs
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
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne "Valid") {
        throw "Tauri Authenticode signing failed: $($signature.Status)"
    }
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
"$hash  $(Split-Path -Leaf $installer)" | Set-Content -Encoding ascii "$installer.sha256"
Write-Output "Windows installer created: $installer"

if ($RequireUpdaterArtifacts) {
    $updaterBundle = Get-ChildItem -LiteralPath $bundleDirectory -Filter "*.exe" -File |
        Select-Object -First 1
    if ($null -eq $updaterBundle) {
        throw "Tauri updater installer was not found in $bundleDirectory"
    }

    $updaterSignature = Get-Item -LiteralPath "$($updaterBundle.FullName).sig" `
        -ErrorAction SilentlyContinue
    if ($null -eq $updaterSignature) {
        throw "Tauri updater signature was not found for $($updaterBundle.Name)"
    }

    $publishedUpdaterBundle = Join-Path $output "Lithe-$Version-windows-x64-updater.exe"
    Copy-Item -LiteralPath $updaterBundle.FullName -Destination $publishedUpdaterBundle -Force
    Copy-Item -LiteralPath $updaterSignature.FullName `
        -Destination "$publishedUpdaterBundle.sig" -Force
    Write-Output "Windows updater bundle created: $publishedUpdaterBundle"
}
