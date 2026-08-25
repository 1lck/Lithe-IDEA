[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [string]$RustTarget = "x86_64-pc-windows-msvc"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$windowsApp = Join-Path $root "windows/tauri"
$bundledExtensionsSource = [System.IO.Path]::GetFullPath((Join-Path $windowsApp "src/extensions/bundled"))
if (-not (Test-Path -LiteralPath $bundledExtensionsSource -PathType Container)) {
    throw "Bundled extensions source directory is missing: $bundledExtensionsSource"
}
$prepareOutput = @(& (Join-Path $root "scripts/prepare-jdtls.ps1"))
if ($prepareOutput.Count -eq 0) {
    throw "JDTLS preparation did not return an output directory."
}
$preparedJdtlsRoot = [System.IO.Path]::GetFullPath([string]$prepareOutput[-1])

$jdkPrepareOutput = @(& (Join-Path $root "scripts/prepare-jdk.ps1") -RustTarget $RustTarget)
if ($jdkPrepareOutput.Count -eq 0) {
    throw "JDK preparation did not return an output directory."
}
$preparedJdkRoot = [System.IO.Path]::GetFullPath([string]$jdkPrepareOutput[-1])
Set-Location $windowsApp

if ($null -eq (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw "Bun is required to build the Windows application."
}

& rustup target add $RustTarget
if ($LASTEXITCODE -ne 0) { throw "Could not install Rust target $RustTarget" }

& (Join-Path $root "scripts/install-windows-frontend-dependencies.ps1")

& bun run typecheck
if ($LASTEXITCODE -ne 0) { throw "Windows frontend type check failed" }

$tauriArgs = @(
    "tauri", "build",
    "--no-bundle",
    "--config", "src-tauri/tauri.windows.conf.json",
    "--target", $RustTarget
)
if ($Configuration -eq "Debug") {
    $tauriArgs += "--debug"
} else {
    $tauriArgs += @("--config", "src-tauri/tauri.jdtls.conf.json")
}
& (Join-Path $root "scripts/invoke-windows-tauri-build.ps1") `
    -TauriArguments $tauriArgs `
    -FailureMessage "Windows Tauri build failed"

$profileName = if ($Configuration -eq "Debug") { "debug" } else { "release" }
$cargoTargetRoot = [System.IO.Path]::GetFullPath((Join-Path $windowsApp "src-tauri/target"))
$profileRoot = [System.IO.Path]::GetFullPath(
    (Join-Path (Join-Path $cargoTargetRoot $RustTarget) $profileName)
)
$trimCharacters = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$targetPrefix = $cargoTargetRoot.TrimEnd($trimCharacters) + [System.IO.Path]::DirectorySeparatorChar
if (-not $profileRoot.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Windows Cargo target profile must stay inside $cargoTargetRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $profileRoot "lithe-windows.exe") -PathType Leaf)) {
    throw "Windows Tauri executable is missing from target profile: $profileRoot"
}

function Copy-ResourceDirectory {
    param(
        [string]$Source,
        [string]$RelativeDestination,
        [string]$IdentityFile = "",
        [string[]]$RequiredPaths = @()
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Bundled resource source directory is missing: $Source"
    }
    $destination = [System.IO.Path]::GetFullPath((Join-Path $profileRoot $RelativeDestination))
    $profilePrefix = $profileRoot.TrimEnd($trimCharacters) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $destination.StartsWith($profilePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Bundled resource destination must stay inside target profile: $destination"
    }
    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $sourceIdentity = Join-Path $Source $IdentityFile
        $destinationIdentity = Join-Path $destination $IdentityFile
        $canReuse = (Test-Path -LiteralPath $sourceIdentity -PathType Leaf) -and
            (Test-Path -LiteralPath $destinationIdentity -PathType Leaf) -and
            (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceIdentity).Hash -eq
                (Get-FileHash -Algorithm SHA256 -LiteralPath $destinationIdentity).Hash
        foreach ($requiredPath in $RequiredPaths) {
            if (-not (Test-Path -LiteralPath (Join-Path $destination $requiredPath))) {
                $canReuse = $false
            }
        }
        if ($canReuse) {
            return $destination
        }
    }
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -Recurse -Force -LiteralPath $destination
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -Recurse -Force -LiteralPath $Source -Destination $destination
    $destination
}

$bundledExtensionsDestination = Copy-ResourceDirectory $bundledExtensionsSource "extensions/bundled"
foreach ($relativePath in @("icon-themes", "themes", "icon-themes/idea/extension.json")) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundledExtensionsDestination $relativePath))) {
        throw "Bundled extensions staging is incomplete: $relativePath"
    }
}

$jdtlsDestination = Copy-ResourceDirectory $preparedJdtlsRoot "LanguageServers/jdtls"
foreach ($relativePath in @("bin/jdtls.bat", "config_win", "plugins")) {
    if (-not (Test-Path -LiteralPath (Join-Path $jdtlsDestination $relativePath))) {
        throw "Bundled JDTLS staging is incomplete: $relativePath"
    }
}

$jdkDestination = Copy-ResourceDirectory `
    -Source $preparedJdkRoot `
    -RelativeDestination "LanguageServers/jdk" `
    -IdentityFile ".lithe-jdk.json" `
    -RequiredPaths @("bin/java.exe", "lib")
foreach ($relativePath in @("bin/java.exe", "lib")) {
    if (-not (Test-Path -LiteralPath (Join-Path $jdkDestination $relativePath))) {
        throw "Bundled JDK staging is incomplete: $relativePath"
    }
}

Write-Output "Windows Tauri build completed."
