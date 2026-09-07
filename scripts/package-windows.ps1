[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$RustTarget = "x86_64-pc-windows-msvc",
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
$bundledExtensionsSource = [System.IO.Path]::GetFullPath((Join-Path $windowsApp "src/extensions/bundled"))
$output = Join-Path $root $OutputDirectory
$taskTempRoot = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetTempPath()
} else {
    $env:RUNNER_TEMP
}
$versionConfig = Join-Path $taskTempRoot "lithe-tauri-version.json"

if (-not (Test-Path -LiteralPath $bundledExtensionsSource -PathType Container)) {
    throw "Bundled extensions source directory is missing: $bundledExtensionsSource"
}
foreach ($relativePath in @("icon-themes", "themes", "icon-themes/idea/extension.json")) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundledExtensionsSource $relativePath))) {
        throw "Bundled extensions source is incomplete: $relativePath"
    }
}

$preparedJdtlsOutput = @(& (Join-Path $root "scripts/prepare-jdtls.ps1"))
if ($preparedJdtlsOutput.Count -eq 0) {
    throw "JDTLS preparation did not return an output directory."
}
$preparedJdtlsRoot = [System.IO.Path]::GetFullPath([string]$preparedJdtlsOutput[-1])
$preparedJdkOutput = @(& (Join-Path $root "scripts/prepare-jdk.ps1") -RustTarget $RustTarget)
if ($preparedJdkOutput.Count -eq 0) {
    throw "JDK preparation did not return an output directory."
}
$preparedJdkRoot = [System.IO.Path]::GetFullPath([string]$preparedJdkOutput[-1])
foreach ($requiredPath in @(
    (Join-Path $preparedJdtlsRoot "bin/jdtls.bat"),
    (Join-Path $preparedJdtlsRoot "plugins"),
    (Join-Path $preparedJdtlsRoot "config_win"),
    (Join-Path $preparedJdtlsRoot "lombok/lombok.jar"),
    (Join-Path $preparedJdkRoot "bin/java.exe"),
    (Join-Path $preparedJdkRoot "lib")
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Bundled Java tooling preparation is incomplete: $requiredPath"
    }
}
$equinoxLauncher = Get-ChildItem -LiteralPath (Join-Path $preparedJdtlsRoot "plugins") `
    -File -Filter "org.eclipse.equinox.launcher_*.jar" | Sort-Object Name | Select-Object -First 1
if ($null -eq $equinoxLauncher) {
    throw "Bundled Java tooling preparation has no JDTLS Equinox launcher JAR."
}

function Sync-BundleResource {
    param([string]$Source, [string]$Destination)

    $sourcePath = [System.IO.Path]::GetFullPath($Source)
    $destinationPath = [System.IO.Path]::GetFullPath($Destination)
    if ($sourcePath.Equals($destinationPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    $artifactsRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".artifacts"))
    $trimCharacters = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $artifactsPrefix = $artifactsRoot.TrimEnd($trimCharacters) +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $destinationPath.StartsWith(
        $artifactsPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Bundled Java tooling destination must stay inside $artifactsRoot"
    }
    if (Test-Path -LiteralPath $destinationPath) {
        Remove-Item -Recurse -Force -LiteralPath $destinationPath
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
    Copy-Item -Recurse -Force -LiteralPath $sourcePath -Destination $destinationPath
}

# tauri.jdtls.conf.json consumes these canonical paths even when a developer
# supplies a verified external runtime through an environment override.
Sync-BundleResource $preparedJdtlsRoot (Join-Path $root ".artifacts/jdtls")
Sync-BundleResource $preparedJdkRoot (Join-Path $root ".artifacts/jdk")

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
& rustup target add $RustTarget
if ($LASTEXITCODE -ne 0) { throw "Could not install Rust target $RustTarget" }

& (Join-Path $root "scripts/install-windows-frontend-dependencies.ps1")

& bun run typecheck
if ($LASTEXITCODE -ne 0) { throw "Windows frontend type check failed" }

$tauriArgs = @(
    "tauri", "build",
    "--config", "src-tauri/tauri.windows.conf.json",
    "--config", "src-tauri/tauri.jdtls.conf.json",
    "--config", $versionConfig,
    "--target", $RustTarget,
    "--bundles", "nsis"
)
if ($Configuration -eq "Debug") { $tauriArgs += "--debug" }
& (Join-Path $root "scripts/invoke-windows-tauri-build.ps1") `
    -TauriArguments $tauriArgs `
    -FailureMessage "Tauri NSIS packaging failed"

$profileName = if ($Configuration -eq "Debug") { "debug" } else { "release" }
$cargoTargetRoot = [System.IO.Path]::GetFullPath((Join-Path $windowsApp "src-tauri/target"))
$profileRoot = [System.IO.Path]::GetFullPath(
    (Join-Path (Join-Path $cargoTargetRoot $RustTarget) $profileName)
)
$trimCharacters = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$targetPrefix = $cargoTargetRoot.TrimEnd($trimCharacters) + [System.IO.Path]::DirectorySeparatorChar
if (-not $profileRoot.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Windows Cargo target profile must stay inside $cargoTargetRoot"
}
$bundleDirectory = Join-Path $profileRoot "bundle/nsis"
$bundleName = "Lithe_${Version}_x64-setup.exe"
$bundle = Get-Item -LiteralPath (Join-Path $bundleDirectory $bundleName) -ErrorAction SilentlyContinue
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
