[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [string]$RustTarget = "x86_64-pc-windows-msvc"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$windowsApp = Join-Path $root "windows/tauri"
& (Join-Path $root "scripts/prepare-jdtls.ps1") | Out-Null
Set-Location $windowsApp

if ($null -eq (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw "Bun is required to build the Windows application."
}

& rustup target add $RustTarget
if ($LASTEXITCODE -ne 0) { throw "Could not install Rust target $RustTarget" }

& bun install --frozen-lockfile
if ($LASTEXITCODE -ne 0) { throw "Windows frontend dependency installation failed" }

& bun run typecheck
if ($LASTEXITCODE -ne 0) { throw "Windows frontend type check failed" }

$tauriArgs = @(
    "tauri", "build",
    "--no-bundle",
    "--config", "src-tauri/tauri.windows.conf.json",
    "--target", $RustTarget
)
if ($Configuration -eq "Debug") { $tauriArgs += "--debug" }
& bunx @tauriArgs
if ($LASTEXITCODE -ne 0) { throw "Windows Tauri build failed" }

Write-Output "Windows Tauri build completed."
