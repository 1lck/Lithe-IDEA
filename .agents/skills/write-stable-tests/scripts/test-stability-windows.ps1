<#
.SYNOPSIS
Run the current Viva desktop Go tests with bounded per-test timing.
.PARAMETER Scope
DesktopGo is the only supported scope. All, Frontend, WindowsRust and
SharedRust* were retired with the old clients and in-repository Core.
Run Rust checks in the external Core checkout linked by the desktop wrapper.
#>
[CmdletBinding()]
param(
    [ValidateSet("DesktopGo")]
    [string]$Scope = "DesktopGo",
    [ValidateRange(1, 3600)]
    [int]$WarnSeconds = 1,
    [ValidateRange(1, 3600)]
    [int]$MaxSeconds = 15,
    [ValidateRange(1, 7200)]
    [int]$SuiteTimeoutSeconds = 1200,
    [string]$GoTestPattern = ".",
    [string[]]$GoPackages = @("./...")
)

$ErrorActionPreference = "Stop"
if ($WarnSeconds -ge $MaxSeconds) { throw "WarnSeconds must be lower than MaxSeconds." }

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../../.."))
foreach ($source in @("desktop/go.mod", "scripts/desktop/desktop-go.sh")) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $source) -PathType Leaf)) {
        throw "DesktopGo test source is missing: $source. Use a complete current desktop checkout."
    }
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "The Windows test stability harness requires Node.js."
}

$reportRoot = Join-Path $root ".artifacts/test-stability"
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null

& (Join-Path $PSScriptRoot "verify-test-stability.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$warnMilliseconds = $WarnSeconds * 1000
$maxMilliseconds = $MaxSeconds * 1000
$suiteTimeoutMilliseconds = $SuiteTimeoutSeconds * 1000

# The system's bash.exe can be the WSL launcher. Use the Bash installed
# with Git for Windows, as the desktop wrapper relies on MSYS and cygpath.
$git = Get-Command git.exe -ErrorAction Stop
. (Join-Path $PSScriptRoot "git-bash-path.ps1")
$gitTools = Resolve-GitForWindowsTools -GitPath $git.Source
$bash = $gitTools.Bash
$cygpath = $gitTools.Cygpath
$wrapper = Join-Path $root "scripts/desktop/desktop-go.sh"
# Calling cygpath directly avoids PowerShell 5 stripping the inner quotes
# of a bash -c command when the native path contains spaces.
$wrapperUnix = & $cygpath -u $wrapper
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wrapperUnix)) {
    throw "Could not convert the desktop wrapper path for Git Bash."
}
$arguments = @(
    (Join-Path $PSScriptRoot "run-go-tests-with-timing.mjs"),
    "--warn-ms", $warnMilliseconds,
    "--max-ms", $maxMilliseconds,
    "--suite-timeout-ms", $suiteTimeoutMilliseconds,
    "--report", (Join-Path $reportRoot "windows-desktop-go.json"),
    "--", $bash, $wrapperUnix.Trim(), "test", "-json", "-count=1", "-p=1", "-parallel=1",
    "-timeout=${SuiteTimeoutSeconds}s", "-run", $GoTestPattern
) + $GoPackages
& node @arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
