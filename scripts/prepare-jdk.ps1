# Stages the bundled JDTLS runtime JDK into .artifacts/jdk.
# This JDK only runs the Java language server. Project SDKs stay user-owned.

[CmdletBinding()]
param(
    [string]$OutputDirectory = "",
    [string]$RustTarget = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root "third_party/jdk/manifest.json"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

$requestedOutput = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    if (-not [string]::IsNullOrWhiteSpace($env:LITHE_JDK_ROOT)) {
        $env:LITHE_JDK_ROOT
    } else {
        Join-Path $root ".artifacts/jdk"
    }
} else {
    $OutputDirectory
}
$output = [System.IO.Path]::GetFullPath($requestedOutput)
$cache = Join-Path $root ".artifacts/jdk-downloads"

function Resolve-PlatformKey {
    if (-not [string]::IsNullOrWhiteSpace($RustTarget)) {
        switch ($RustTarget) {
            "x86_64-pc-windows-msvc" { return "windows-x86_64" }
            "aarch64-pc-windows-msvc" { return "windows-aarch64" }
            default { throw "Unsupported Windows Rust target for the bundled JDK: $RustTarget" }
        }
    }

    if ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq
        [System.Runtime.InteropServices.Architecture]::Arm64) {
        return "windows-aarch64"
    }
    "windows-x86_64"
}

$platformKey = Resolve-PlatformKey

$jdkVersion  = $manifest.version
$platform    = $manifest.platforms.$platformKey
if ($null -eq $platform) { throw "The bundled JDK manifest has no platform entry for $platformKey" }
$archiveUrl  = $platform.url
$archiveSha256 = $platform.sha256.ToLowerInvariant()

$safeVersion = $jdkVersion -replace '[^A-Za-z0-9._-]', '_'
$archivePath = Join-Path $cache "jdk-$safeVersion-$platformKey-$archiveSha256.zip"
$stampPath = Join-Path $output ".lithe-jdk.json"

function Get-FileSHA256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$ExpectedSHA256,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Description
    )
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $actualHash = Get-FileSHA256 -Path $Destination
        if ($actualHash -eq $ExpectedSHA256) { return }
        Write-Warning "$Description cache checksum mismatch; removing it before retrying the download"
        Remove-Item -Force -LiteralPath $Destination
    }
    $temporaryPath = "$Destination.download-$PID"
    try {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -Force -LiteralPath $temporaryPath }
        Invoke-WebRequest -Uri $Uri -OutFile $temporaryPath
        $actualHash = Get-FileSHA256 -Path $temporaryPath
        if ($actualHash -ne $ExpectedSHA256) {
            throw "$Description checksum mismatch: expected $ExpectedSHA256, got $actualHash"
        }
        Move-Item -Force -LiteralPath $temporaryPath -Destination $Destination
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -Force -LiteralPath $temporaryPath }
    }
}

function Assert-JdkOutput {
    $javaExe = Join-Path $output "bin\java.exe"
    if (-not (Test-Path -LiteralPath $javaExe -PathType Leaf)) {
        throw "Bundled JDK java.exe is missing: $javaExe"
    }
    $libDirectory = Join-Path $output "lib"
    if (-not (Test-Path -LiteralPath $libDirectory -PathType Container)) {
        throw "Bundled JDK lib directory is missing: $libDirectory"
    }

    # Windows PowerShell 5 surfaces a native process's stderr as an error
    # record. Java writes its version to stderr, so temporarily allow that
    # stream to be captured without turning a successful probe into a failure.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $versionOutput = (& $javaExe -version 2>&1) -join [Environment]::NewLine
        $javaExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($javaExitCode -ne 0) {
        throw "Bundled JDK java.exe version probe failed with exit code $javaExitCode"
    }
    if ($versionOutput -notmatch '"21\.') {
        throw "Bundled JDK reported an unexpected version: $versionOutput"
    }
}

function Test-PreparedJdk {
    if (-not (Test-Path -LiteralPath $stampPath -PathType Leaf)) { return $false }
    try {
        $stamp = Get-Content -Raw -LiteralPath $stampPath | ConvertFrom-Json
        if ($stamp.schemaVersion -ne 1 -or
            $stamp.manifestVersion -ne $jdkVersion -or
            $stamp.platform -ne $platformKey -or
            $stamp.archiveSHA256 -ne $archiveSha256) {
            return $false
        }
        Assert-JdkOutput
        return $true
    } catch {
        Write-Warning "Prepared bundled JDK is invalid and will be rebuilt: $($_.Exception.Message)"
        return $false
    }
}

# If LITHE_JDK_ROOT is set externally, just validate and return.
if (-not [string]::IsNullOrWhiteSpace($env:LITHE_JDK_ROOT) -and
    [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Assert-JdkOutput
    Write-Output $output
    exit 0
}

if (Test-PreparedJdk) {
    Write-Output $output
    exit 0
}

New-Item -ItemType Directory -Force -Path $cache | Out-Null
Get-VerifiedDownload -Uri $archiveUrl -ExpectedSHA256 $archiveSha256 `
    -Destination $archivePath -Description "Temurin JDK archive"

if (Test-Path -LiteralPath $output) { Remove-Item -Recurse -Force -LiteralPath $output }

$staging = Join-Path $cache "staging-$PID"
if (Test-Path -LiteralPath $staging) { Remove-Item -Recurse -Force -LiteralPath $staging }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

try {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $staging

    # Windows Temurin archives contain a single top-level directory (e.g. jdk-21.0.12+8).
    # Move its contents to the final output path.
    $inner = Get-ChildItem -LiteralPath $staging -Directory | Select-Object -First 1
    if ($null -eq $inner) { throw "Could not locate JDK directory inside the Temurin archive" }
    Move-Item -LiteralPath $inner.FullName -Destination $output
    @{
        schemaVersion = 1
        manifestVersion = $jdkVersion
        platform = $platformKey
        archiveSHA256 = $archiveSha256
    } | ConvertTo-Json | Set-Content -LiteralPath $stampPath -Encoding ascii
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -Recurse -Force -LiteralPath $staging }
}

Assert-JdkOutput
Write-Output $output
