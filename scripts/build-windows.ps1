[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [string]$Version = "0.1.11",
    [string]$RustTarget = "x86_64-pc-windows-msvc",
    [string]$BuildDirectory = "windows/build-windows",
    [switch]$BuildWinUI
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

$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& rustup target add $RustTarget
$rustupExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
if ($rustupExit -ne 0) { throw "Could not install Rust target $RustTarget" }
$cargoArgs = @(
    "build",
    "--manifest-path", "rust/Cargo.toml",
    "--target", $RustTarget
)
$cargoArgs += $profileArgs
$ErrorActionPreference = "Continue"
& cargo @cargoArgs
$cargoExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
if ($cargoExit -ne 0) { throw "Rust core build failed" }

$rustProfile = if ($Configuration -eq "Release") { "release" } else { "debug" }
$rustOutput = Join-Path $targetDirectory "$RustTarget/$rustProfile"
$rustLibrary = Get-ChildItem -LiteralPath $rustOutput -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @("lithe_core.lib", "liblithe_core.a") } |
    Select-Object -First 1
if ($null -eq $rustLibrary) {
    throw "Rust static library was not found in $rustOutput"
}

$cmakeBuild = Join-Path $root $BuildDirectory
& cmake -S windows -B $cmakeBuild `
    "-DCMAKE_BUILD_TYPE=$Configuration" `
    "-DLITHE_VERSION=$Version" `
    "-DLITHE_BUILD_QT_UI=OFF" `
    "-DLITHE_RUST_CORE_LIBRARY=$($rustLibrary.FullName)"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

& cmake --build $cmakeBuild --config $Configuration --parallel -- /nr:false
if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

if ($BuildWinUI) {
    $msbuild = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($null -eq $msbuild) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} `
            "Microsoft Visual Studio/Installer/vswhere.exe"
        if (Test-Path -LiteralPath $vswhere) {
            # The WinUI project intentionally targets the VS 2022 v143
            # toolset. Hosted runners can also contain VS 18 previews, whose
            # MSBuild cannot supply the v143 UWP/WinUI targets.
            $installationPath = & $vswhere -latest -version "[17.0,18.0)" -products * `
                -requires Microsoft.Component.MSBuild -property installationPath
            if ($LASTEXITCODE -eq 0 -and $installationPath) {
                $candidate = Join-Path $installationPath "MSBuild/Current/Bin/MSBuild.exe"
                if (Test-Path -LiteralPath $candidate) {
                    $msbuild = Get-Item -LiteralPath $candidate
                }
            }
        }
    }
    if ($null -eq $msbuild) {
        throw "MSBuild was not found in PATH or a Visual Studio 2022 installation."
    }
    $winUIPlatform = switch -Wildcard ($RustTarget) {
        "aarch64-*" { "ARM64"; break }
        "x86_64-*" { "x64"; break }
        default { throw "WinUI build does not support Rust target $RustTarget" }
    }
    $winUIProject = Join-Path $root "windows/winui/Lithe.WinUI.vcxproj"
    $msbuildArgs = @(
        $winUIProject,
        "/restore",
        "/m",
        "/nr:false",
        "/p:Configuration=$Configuration",
        "/p:Platform=$winUIPlatform",
        "/p:LitheRustCoreLibrary=$($rustLibrary.FullName)"
    )
    $msbuildPath = if ($msbuild.Source) { $msbuild.Source } else { $msbuild.FullName }
    & $msbuildPath @msbuildArgs
    if ($LASTEXITCODE -ne 0) { throw "WinUI 3 build failed" }
}

Write-Output "Windows build completed: $cmakeBuild"
