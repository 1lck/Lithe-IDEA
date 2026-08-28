[CmdletBinding()]
param(
    [ValidateSet("windows", "macos", "all")]
    [string]$Platform = "windows",
    [string]$BaseRevision,
    [string]$HeadRevision = "HEAD",
    [switch]$All
)

$ErrorActionPreference = "Stop"
$arguments = @(
    (Join-Path $PSScriptRoot "verify-test-stability.mjs"),
    "--platform",
    $Platform
)
if ($All) { $arguments += "--all" }
if (-not [string]::IsNullOrWhiteSpace($BaseRevision)) {
    $arguments += @("--base", $BaseRevision, "--head", $HeadRevision)
}

& node @arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
