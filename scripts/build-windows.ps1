[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [string]$RustTarget = "x86_64-pc-windows-msvc"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$windowsApp = Join-Path $root "windows/tauri"
if ($Configuration -eq "Release") {
    & (Join-Path $root "scripts/prepare-jdtls.ps1") | Out-Null
}
Set-Location $windowsApp

if ($null -eq (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw "Bun is required to build the Windows application."
}

function Add-DirectoryToPath([string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $existing = $env:Path -split ";" | Where-Object { $_ -ne "" }
    if ($existing -contains $Directory) { return }
    $env:Path = "$Directory;" + $env:Path
}

# bunx hides rustup/nodejs shims from Tauri's cargo lookup on Windows.
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

& rustup target add $RustTarget
if ($LASTEXITCODE -ne 0) { throw "Could not install Rust target $RustTarget" }

if ($null -eq (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "Cargo is required to build the Windows application."
}

& bun install --frozen-lockfile
if ($LASTEXITCODE -ne 0) { throw "Windows frontend dependency installation failed" }

& bun run typecheck
if ($LASTEXITCODE -ne 0) { throw "Windows frontend type check failed" }

$tauriArgs = @(
    "tauri",
    "--",
    "build",
    "--no-bundle",
    "--config", "src-tauri/tauri.windows.conf.json",
    "--target", $RustTarget
)
if ($Configuration -eq "Debug") {
    $tauriArgs += "--debug"
} else {
    $tauriArgs += @("--config", "src-tauri/tauri.jdtls.conf.json")
}
# Use the workspace @tauri-apps/cli. `bunx tauri` drops cargo from PATH.
& bun run @tauriArgs
if ($LASTEXITCODE -ne 0) { throw "Windows Tauri build failed" }

Write-Output "Windows Tauri build completed."
