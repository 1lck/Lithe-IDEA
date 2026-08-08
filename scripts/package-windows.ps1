[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$Version = "0.0.0",
    [string]$BuildDirectory = "windows/build-windows",
    [string]$OutputDirectory = "dist",
    [string]$CertificateThumbprint = $env:LITHE_WINDOWS_CERTIFICATE_THUMBPRINT,
    [string]$TimestampServer = $env:LITHE_WINDOWS_TIMESTAMP_SERVER,
    [switch]$RequireAuthenticodeSignature
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$binary = Join-Path $root "$BuildDirectory/$Configuration/lithe_windows_qt.exe"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    $binary = Join-Path $root "$BuildDirectory/lithe_windows_qt.exe"
}
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "Qt workbench executable was not found. Build with -BuildQt first."
}
$updateHelper = Join-Path $root "$BuildDirectory/$Configuration/lithe_windows_update_helper.exe"
if (-not (Test-Path -LiteralPath $updateHelper -PathType Leaf)) {
    $updateHelper = Join-Path $root "$BuildDirectory/lithe_windows_update_helper.exe"
}
if (-not (Test-Path -LiteralPath $updateHelper -PathType Leaf)) {
    throw "Windows update helper was not found. Build the Windows targets first."
}

$windeployqt = Get-Command windeployqt.exe -ErrorAction SilentlyContinue
if ($null -eq $windeployqt) { throw "windeployqt.exe was not found on PATH." }
$makensis = Get-Command makensis.exe -ErrorAction SilentlyContinue
if ($null -eq $makensis) { throw "makensis.exe was not found on PATH." }
$icon = Join-Path $root "windows/packaging/lithe.ico"
if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) {
    throw "Windows application icon was not found: $icon"
}

$output = Join-Path $root $OutputDirectory
$stage = Join-Path $output "lithe-stage"
New-Item -ItemType Directory -Force -Path $output | Out-Null
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

& $windeployqt.Source --release --no-translations --no-system-d3d-compiler `
    --dir $stage $binary
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed." }
Copy-Item -LiteralPath $updateHelper -Destination $stage -Force

$installer = Join-Path $output "Lithe-$Version-windows-x64.exe"
& $makensis.Source "/DPRODUCT_VERSION=$Version" "/DINPUT_DIR=$stage" `
    "/DOUTPUT_FILE=$installer" "windows/packaging/lithe.nsi"
if ($LASTEXITCODE -ne 0) { throw "NSIS failed." }

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
} else {
    if ($RequireAuthenticodeSignature) {
        throw "Authenticode signing is required but no certificate thumbprint was configured."
    }
    Write-Warning "No Authenticode certificate was configured; the installer will be rejected by the in-app updater."
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
"$hash  $(Split-Path -Leaf $installer)" | Set-Content -Encoding ascii "$installer.sha256"
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Output "Windows installer created: $installer"
