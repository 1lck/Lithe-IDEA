[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$windowsApp = Join-Path $root "windows/tauri"
$package = Get-Content -Raw -LiteralPath (Join-Path $windowsApp "package.json") | ConvertFrom-Json
$expectedVersion = ([string]$package.packageManager) -replace '^bun@', ''
$bunCache = [System.IO.Path]::GetFullPath((Join-Path $root ".artifacts/bun-cache"))
$nodeModules = [System.IO.Path]::GetFullPath((Join-Path $windowsApp "node_modules"))
$env:BUN_INSTALL_CACHE_DIR = $bunCache

function Write-CacheWarning {
    param([string]$Message)

    Write-Warning $Message
    if ($env:GITHUB_ACTIONS -eq "true") {
        $escaped = $Message.Replace("%", "%25").Replace("`r", "%0D").Replace("`n", "%0A")
        Write-Output "::warning title=Bun cache fallback::$escaped"
    }
}

if ($null -eq (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw "Bun is required to install Windows frontend dependencies."
}
$actualVersion = [string](& bun --version | Select-Object -Last 1)
$actualVersion = $actualVersion.Trim()
if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $expectedVersion) {
    throw "Bun $expectedVersion is required, but $actualVersion is active."
}

New-Item -ItemType Directory -Force -Path $bunCache | Out-Null
Push-Location $windowsApp
try {
    & bun install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) {
        Write-CacheWarning "The cached Bun install failed. Clearing repository-scoped cache data and retrying with ordinary downloads."
        if (Test-Path -LiteralPath $bunCache) { Remove-Item -Recurse -Force -LiteralPath $bunCache }
        if (Test-Path -LiteralPath $nodeModules) { Remove-Item -Recurse -Force -LiteralPath $nodeModules }
        New-Item -ItemType Directory -Force -Path $bunCache | Out-Null
        & bun install --frozen-lockfile --no-cache
        if ($LASTEXITCODE -ne 0) {
            throw "Windows frontend dependency installation failed after a clean retry."
        }
    }

    if ($env:LITHE_BUN_CACHE_VERIFIED -ne "true" -or
        -not (Test-Path -LiteralPath (Join-Path $bunCache ".lithe-integrity.json") -PathType Leaf)) {
        & node (Join-Path $root "scripts/verify-windows-download-cache.mjs") `
            --cargo-cache (Join-Path $root ".artifacts/cargo-home/registry/cache") `
            --cargo-lock (Join-Path $root "rust/Cargo.lock") `
            --cargo-lock (Join-Path $root "windows/tauri/src-tauri/Cargo.lock") `
            --bun-version $expectedVersion `
            --bun-lock (Join-Path $windowsApp "bun.lock") `
            --bun-cache $bunCache `
            --write-bun-manifest
        if ($LASTEXITCODE -ne 0) { throw "Could not seal the Bun download cache." }
    }
} finally {
    Pop-Location
}
