[CmdletBinding()]
param(
    [string]$CargoDownloadsOutcome = "skipped",
    [string]$CargoBuildOutcome = "skipped",
    [string]$CargoBuildHit = "",
    [string]$BunOutcome = "skipped",
    [string]$JdtlsOutcome = "skipped",
    [string]$JdkOutcome = "skipped",
    [switch]$IncludeWindowsAssets
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$artifactsRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".artifacts"))
$cargoHome = Join-Path $artifactsRoot "cargo-home"
$bunCache = Join-Path $artifactsRoot "bun-cache"
$jdtlsCache = Join-Path $artifactsRoot "jdtls-downloads"
$jdkCache = Join-Path $artifactsRoot "jdk-downloads"

function Write-CacheWarning {
    param([string]$Title, [string]$Message)

    if ($env:GITHUB_ACTIONS -eq "true") {
        $escaped = $Message.Replace("%", "%25").Replace("`r", "%0D").Replace("`n", "%0A")
        Write-Output "::warning title=$Title::$escaped"
    } else {
        Write-Warning "$Title`: $Message"
    }
}

function Reset-GeneratedPath {
    param([string]$Path)

    $resolved = [System.IO.Path]::GetFullPath($Path)
    $trimCharacters = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $repositoryPrefix = [System.IO.Path]::GetFullPath($root).TrimEnd($trimCharacters) +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clear cache path outside the repository: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -Recurse -Force -LiteralPath $resolved
    }
}

if ($CargoDownloadsOutcome -eq "failure") {
    Write-CacheWarning "Cargo cache restore failed" "Discarding the partial download cache and falling back to Cargo downloads."
    Reset-GeneratedPath $cargoHome
}
if ($CargoBuildOutcome -eq "failure") {
    Write-CacheWarning "Cargo build cache restore failed" "Discarding partial target directories and rebuilding normally."
    Reset-GeneratedPath (Join-Path $root "windows/tauri/src-tauri/target")
    Reset-GeneratedPath (Join-Path $root "rust/target")
}
if ($BunOutcome -eq "failure") {
    Write-CacheWarning "Bun cache restore failed" "Discarding the partial Bun cache and downloading dependencies normally."
    Reset-GeneratedPath $bunCache
}
if ($JdtlsOutcome -eq "failure") {
    Write-CacheWarning "JDTLS cache restore failed" "Discarding the partial JDTLS cache and downloading verified artifacts normally."
    Reset-GeneratedPath $jdtlsCache
}
if ($JdkOutcome -eq "failure") {
    Write-CacheWarning "JDK cache restore failed" "Discarding the partial JDK cache and downloading verified artifacts normally."
    Reset-GeneratedPath $jdkCache
}

$validatorArguments = @(
    (Join-Path $root "scripts/verify-download-cache.mjs"),
    "--cargo-cache", (Join-Path $cargoHome "registry/cache"),
    "--cargo-lock", (Join-Path $root "rust/Cargo.lock"),
    "--cargo-lock", (Join-Path $root "windows/tauri/src-tauri/Cargo.lock")
)
if ($IncludeWindowsAssets) {
    $package = Get-Content -Raw -LiteralPath (Join-Path $root "windows/tauri/package.json") | ConvertFrom-Json
    $bunVersion = ([string]$package.packageManager) -replace '^bun@', ''
    if ([string]::IsNullOrWhiteSpace($bunVersion)) {
        throw "windows/tauri/package.json must declare packageManager as bun@<version>."
    }
    $validatorArguments += @(
        "--jdtls-cache", $jdtlsCache,
        "--jdtls-manifest", (Join-Path $root "third_party/jdtls/manifest.json"),
        "--jdk-cache", $jdkCache,
        "--jdk-manifest", (Join-Path $root "third_party/jdk/manifest.json"),
        "--bun-version", $bunVersion,
        "--bun-lock", (Join-Path $root "windows/tauri/bun.lock"),
        "--bun-cache", $bunCache
    )
}

& node @validatorArguments
if ($LASTEXITCODE -ne 0) {
    Write-CacheWarning "Cache validation failed" "The validator could not trust the restored downloads; all download caches will be rebuilt normally."
    Reset-GeneratedPath $cargoHome
    if ($IncludeWindowsAssets) {
        Reset-GeneratedPath $bunCache
        Reset-GeneratedPath $jdtlsCache
        Reset-GeneratedPath $jdkCache
    }
}

$buildCacheRestored = $CargoBuildOutcome -eq "success" -and
    ($CargoBuildHit -eq "true" -or $CargoBuildHit -eq "false")
if ($null -ne $env:GITHUB_ENV) {
    "LITHE_CARGO_BUILD_CACHE_RESTORED=$($buildCacheRestored.ToString().ToLowerInvariant())" >> $env:GITHUB_ENV
    $bunManifest = Join-Path $bunCache ".lithe-integrity.json"
    $bunCacheVerified = $IncludeWindowsAssets -and (Test-Path -LiteralPath $bunManifest -PathType Leaf)
    "LITHE_BUN_CACHE_VERIFIED=$($bunCacheVerified.ToString().ToLowerInvariant())" >> $env:GITHUB_ENV
}
exit 0
