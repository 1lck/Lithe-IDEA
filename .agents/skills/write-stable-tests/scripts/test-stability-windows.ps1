[CmdletBinding()]
param(
    [ValidateSet("All", "Frontend", "WindowsRust", "SharedRust")]
    [string]$Scope = "All",
    [ValidateRange(1, 3600)]
    [int]$WarnSeconds = 1,
    [ValidateRange(1, 3600)]
    [int]$MaxSeconds = 15,
    [ValidateRange(1, 7200)]
    [int]$SuiteTimeoutSeconds = 1200,
    [string[]]$FrontendTestPath = @()
)

$ErrorActionPreference = "Stop"
if ($WarnSeconds -ge $MaxSeconds) { throw "WarnSeconds must be lower than MaxSeconds." }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "The Windows test stability harness requires Node.js."
}
if ($Scope -in @("All", "Frontend") -and -not (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw "Bun is required only for the Windows Frontend scope. Use WindowsRust or SharedRust without Bun."
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../../.."))
$reportRoot = Join-Path $root ".artifacts/test-stability"
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null

& (Join-Path $PSScriptRoot "verify-test-stability.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$warnMilliseconds = $WarnSeconds * 1000
$maxMilliseconds = $MaxSeconds * 1000
$suiteTimeoutMilliseconds = $SuiteTimeoutSeconds * 1000

function Invoke-TimedRustTests {
    param(
        [Parameter(Mandatory)]
        [string]$Manifest,
        [string]$Package,
        [Parameter(Mandatory)]
        [string]$TargetDirectory,
        [Parameter(Mandatory)]
        [string]$Report
    )

    $suiteTimer = [System.Diagnostics.Stopwatch]::StartNew()
    function Get-RemainingRustSuiteMilliseconds {
        $remainingMilliseconds = [Math]::Floor(
            $suiteTimeoutMilliseconds - $suiteTimer.Elapsed.TotalMilliseconds
        )
        if ($remainingMilliseconds -le 0) {
            throw "Rust test suite exceeded the shared $SuiteTimeoutSeconds second deadline."
        }
        return $remainingMilliseconds
    }

    function New-RustTimingArguments {
        $remainingMilliseconds = Get-RemainingRustSuiteMilliseconds
        $arguments = @(
            (Join-Path $PSScriptRoot "run-rust-tests-with-timing.mjs"),
            "--manifest", $Manifest,
            "--warn-ms", $warnMilliseconds,
            "--max-ms", $maxMilliseconds,
            "--build-timeout-ms", $remainingMilliseconds,
            "--suite-timeout-ms", $remainingMilliseconds,
            "--report", $Report
        )
        if (-not [string]::IsNullOrWhiteSpace($Package)) {
            $arguments += @("--package", $Package)
        }
        return $arguments
    }

    if (Test-Path -LiteralPath $Report) { Remove-Item -Force -LiteralPath $Report }
    $arguments = New-RustTimingArguments
    & node @arguments
    if ($LASTEXITCODE -eq 0) { return }
    if (Test-Path -LiteralPath $Report) {
        $suiteTimedOut = $false
        try {
            $timingReport = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
            $suiteTimedOut = $null -ne $timingReport.suite -and $timingReport.suite.timedOut -eq $true
        } catch {
            Write-Warning "Could not inspect the Rust timing report after failure: $($_.Exception.Message)"
        }
        if ($suiteTimedOut) {
            throw "Rust test suite exceeded the shared $SuiteTimeoutSeconds second deadline."
        }
    }
    if ($env:LITHE_CARGO_BUILD_CACHE_RESTORED -ne "true") {
        throw "Rust timing tests failed."
    }

    $null = Get-RemainingRustSuiteMilliseconds
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
    Write-Warning "Rust timing failed after restoring cached build outputs. Clearing $TargetDirectory and retrying once."
    if (Test-Path -LiteralPath $target) { Remove-Item -Recurse -Force -LiteralPath $target }
    if (Test-Path -LiteralPath $Report) { Remove-Item -Force -LiteralPath $Report }
    $arguments = New-RustTimingArguments
    & node @arguments
    if ($LASTEXITCODE -ne 0) { throw "Rust timing tests failed after a clean retry." }
}

if ($Scope -in @("All", "Frontend")) {
    $arguments = @(
        (Join-Path $PSScriptRoot "run-bun-tests-with-timing.mjs"),
        "--working-directory", (Join-Path $root "windows/tauri"),
        "--warn-ms", $warnMilliseconds,
        "--max-ms", $maxMilliseconds,
        "--suite-timeout-ms", $suiteTimeoutMilliseconds,
        "--report", (Join-Path $reportRoot "windows-frontend.json"),
        "--"
    ) + $FrontendTestPath
    & node @arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if ($Scope -in @("All", "WindowsRust")) {
    Invoke-TimedRustTests `
        -Manifest "windows/tauri/src-tauri/Cargo.toml" `
        -TargetDirectory "windows/tauri/src-tauri/target" `
        -Report (Join-Path $reportRoot "windows-rust.json")
}

if ($Scope -in @("All", "SharedRust")) {
    Invoke-TimedRustTests `
        -Manifest "rust/Cargo.toml" `
        -Package "lithe-core" `
        -TargetDirectory "rust/target" `
        -Report (Join-Path $reportRoot "shared-rust.json")
}
