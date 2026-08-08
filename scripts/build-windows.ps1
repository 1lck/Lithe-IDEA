[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [string]$RustTarget = "x86_64-pc-windows-msvc",
    [string]$BuildDirectory = "windows/build-windows",
    [switch]$BuildQt
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$profileArgs = @()
if ($Configuration -eq "Release") {
    $profileArgs += "--release"
}

$targetDirectory = if ($env:LITHE_RUST_TARGET_DIR) {
    $env:LITHE_RUST_TARGET_DIR
} else {
    Join-Path $root "rust/target/windows"
}
$env:CARGO_TARGET_DIR = $targetDirectory

& rustup target add $RustTarget
if ($LASTEXITCODE -ne 0) { throw "Could not install Rust target $RustTarget" }

$cargoArgs = @(
    "build",
    "--manifest-path", "rust/Cargo.toml",
    "--target", $RustTarget
)
$cargoArgs += $profileArgs
& cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { throw "Rust core build failed" }

$rustProfile = if ($Configuration -eq "Release") { "release" } else { "debug" }
$rustOutput = Join-Path $targetDirectory "$RustTarget/$rustProfile"
$rustLibrary = Get-ChildItem -LiteralPath $rustOutput -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @("lithe_core.lib", "liblithe_core.a") } |
    Select-Object -First 1
if ($null -eq $rustLibrary) {
    throw "Rust static library was not found in $rustOutput"
}

$cmakeBuild = Join-Path $root $BuildDirectory
$qtOption = if ($BuildQt) { "ON" } else { "OFF" }
& cmake -S windows -B $cmakeBuild `
    "-DCMAKE_BUILD_TYPE=$Configuration" `
    "-DLITHE_BUILD_QT_UI=$qtOption" `
    "-DLITHE_RUST_CORE_LIBRARY=$($rustLibrary.FullName)"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

& cmake --build $cmakeBuild --config $Configuration --parallel -- /nr:false
if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

Write-Output "Windows build completed: $cmakeBuild"
