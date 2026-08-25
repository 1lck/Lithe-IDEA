[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$TauriArguments,
    [string]$FailureMessage = "Windows Tauri build failed"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$windowsApp = Join-Path $root "windows/tauri"
$targetRoot = [System.IO.Path]::GetFullPath((Join-Path $windowsApp "src-tauri/target"))

function Write-CacheWarning {
    param([string]$Message)

    Write-Warning $Message
    if ($env:GITHUB_ACTIONS -eq "true") {
        $escaped = $Message.Replace("%", "%25").Replace("`r", "%0D").Replace("`n", "%0A")
        Write-Output "::warning title=Cargo build cache fallback::$escaped"
    }
}

Push-Location $windowsApp
try {
    & bunx @TauriArguments
    if ($LASTEXITCODE -eq 0) { return }

    if ($env:LITHE_CARGO_BUILD_CACHE_RESTORED -ne "true") {
        throw $FailureMessage
    }

    Write-CacheWarning "The Tauri build failed after restoring Cargo outputs. Clearing the repository target directory and retrying once without cached outputs."
    if (Test-Path -LiteralPath $targetRoot) {
        Remove-Item -Recurse -Force -LiteralPath $targetRoot
    }
    & bunx @TauriArguments
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage after a clean retry" }
} finally {
    Pop-Location
}
