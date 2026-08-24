[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$windowsApp = Join-Path $root "windows/tauri"
$package = Get-Content -Raw -LiteralPath (Join-Path $windowsApp "package.json") | ConvertFrom-Json
$expectedVersion = ([string]$package.packageManager) -replace '^bun@', ''
$bunCache = [System.IO.Path]::GetFullPath((Join-Path $root ".artifacts/bun-cache"))
$bunTemp = [System.IO.Path]::GetFullPath((Join-Path $root ".artifacts/bun-tmp"))
$nodeModules = [System.IO.Path]::GetFullPath((Join-Path $windowsApp "node_modules"))

function Write-CacheWarning {
    param([string]$Message, [string]$Title = "Bun cache fallback")

    if ($env:GITHUB_ACTIONS -eq "true") {
        $escaped = $Message.Replace("%", "%25").Replace("`r", "%0D").Replace("`n", "%0A")
        Write-Output "::warning title=$Title::$escaped"
    } else {
        Write-Warning "$Title`: $Message"
    }
}

# Bun can expose the original temp path after a cross-volume fallback, while
# creating lifecycle shims such as node-gyp.cmd beside the install cache.
$cacheVolume = [System.IO.Path]::GetPathRoot($bunCache)
$tempVolume = [System.IO.Path]::GetPathRoot($bunTemp)
if (-not $cacheVolume.Equals($tempVolume, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BUN_INSTALL_CACHE_DIR and BUN_TMPDIR must be on the same Windows volume."
}
if ((Test-Path Env:BUN_INSTALL_CACHE_DIR) -and
    -not [string]::Equals($env:BUN_INSTALL_CACHE_DIR, $bunCache, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-CacheWarning "Ignoring an external BUN_INSTALL_CACHE_DIR override; using the verified repository cache: $bunCache" "Bun cache configuration"
}
if ((Test-Path Env:BUN_TMPDIR) -and
    -not [string]::Equals($env:BUN_TMPDIR, $bunTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-CacheWarning "Ignoring an external BUN_TMPDIR override; using the same-volume repository temp directory: $bunTemp" "Bun cache configuration"
}
if ((Test-Path Env:BUN_FEATURE_FLAG_DISABLE_INSTALL_INDEX) -and
    $env:BUN_FEATURE_FLAG_DISABLE_INSTALL_INDEX -ne "1") {
    Write-CacheWarning "Ignoring an external install-index override; the verified Bun cache cannot contain Windows junctions." "Bun cache configuration"
}
$env:BUN_INSTALL_CACHE_DIR = $bunCache
$env:BUN_TMPDIR = $bunTemp
$env:BUN_FEATURE_FLAG_DISABLE_INSTALL_INDEX = "1"

if (Test-Path -LiteralPath $bunTemp) { Remove-Item -Recurse -Force -LiteralPath $bunTemp }
New-Item -ItemType Directory -Force -Path $bunCache, $bunTemp | Out-Null

if ($null -eq (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw "Bun is required to install Windows frontend dependencies."
}
$actualVersion = [string](& bun --version | Select-Object -Last 1)
$actualVersion = $actualVersion.Trim()
if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $expectedVersion) {
    throw "Bun $expectedVersion is required, but $actualVersion is active."
}

Push-Location $windowsApp
try {
    & bun install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) {
        if ($env:LITHE_BUN_CACHE_VERIFIED -eq "true") {
            Write-CacheWarning "The verified Bun cache could not complete installation. Clearing it and retrying with ordinary downloads."
        } else {
            Write-CacheWarning "The initial Bun install failed. Clearing partial data and retrying with ordinary downloads."
        }
        if (Test-Path -LiteralPath $bunCache) { Remove-Item -Recurse -Force -LiteralPath $bunCache }
        if (Test-Path -LiteralPath $bunTemp) { Remove-Item -Recurse -Force -LiteralPath $bunTemp }
        if (Test-Path -LiteralPath $nodeModules) { Remove-Item -Recurse -Force -LiteralPath $nodeModules }
        New-Item -ItemType Directory -Force -Path $bunCache, $bunTemp | Out-Null
        & bun install --frozen-lockfile --no-cache
        if ($LASTEXITCODE -ne 0) {
            throw "Windows frontend dependency installation failed after a clean retry."
        }
    }

    if ($env:LITHE_BUN_CACHE_VERIFIED -ne "true" -or
        -not (Test-Path -LiteralPath (Join-Path $bunCache ".lithe-integrity.json") -PathType Leaf)) {
        $cacheSealed = $false
        try {
            & node (Join-Path $root "scripts/verify-download-cache.mjs") `
                --cargo-cache (Join-Path $root ".artifacts/cargo-home/registry/cache") `
                --cargo-lock (Join-Path $root "rust/Cargo.lock") `
                --cargo-lock (Join-Path $root "windows/tauri/src-tauri/Cargo.lock") `
                --bun-version $expectedVersion `
                --bun-lock (Join-Path $windowsApp "bun.lock") `
                --bun-cache $bunCache `
                --write-bun-manifest
            $cacheSealed = $LASTEXITCODE -eq 0
        } catch {
            Write-Output $_
        }
        if (-not $cacheSealed) {
            Write-CacheWarning "The Bun download cache could not be sealed safely. Discarding it and continuing with the installed dependencies."
            if (Test-Path -LiteralPath $bunCache) { Remove-Item -Recurse -Force -LiteralPath $bunCache }
            if ($null -ne $env:GITHUB_ENV) { "LITHE_BUN_CACHE_VERIFIED=false" >> $env:GITHUB_ENV }
        }
    }
} finally {
    Pop-Location
}
