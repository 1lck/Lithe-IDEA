[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$CargoArguments,
    [Parameter(Mandatory)]
    [string]$TargetDirectory,
    [string]$FailureMessage = "Cargo command failed"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$target = [System.IO.Path]::GetFullPath((Join-Path $root $TargetDirectory))
$trimCharacters = [char[]]@(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
)
$repositoryPrefix = [System.IO.Path]::GetFullPath($root).TrimEnd($trimCharacters) +
    [System.IO.Path]::DirectorySeparatorChar
if (-not $target.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Cargo target directory must stay inside the repository: $target"
}

function Write-CacheWarning {
    param([string]$Message)

    Write-Warning $Message
    if ($env:GITHUB_ACTIONS -eq "true") {
        $escaped = $Message.Replace("%", "%25").Replace("`r", "%0D").Replace("`n", "%0A")
        Write-Output "::warning title=Cargo build cache fallback::$escaped"
    }
}

& cargo @CargoArguments
if ($LASTEXITCODE -eq 0) { exit 0 }
if ($env:LITHE_CARGO_BUILD_CACHE_RESTORED -ne "true") { throw $FailureMessage }

Write-CacheWarning "Cargo failed after restoring build outputs. Clearing $TargetDirectory and retrying once without cached outputs."
if (Test-Path -LiteralPath $target) { Remove-Item -Recurse -Force -LiteralPath $target }
& cargo @CargoArguments
if ($LASTEXITCODE -ne 0) { throw "$FailureMessage after a clean retry" }
