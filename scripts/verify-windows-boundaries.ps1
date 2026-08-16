$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$cppFiles = Get-ChildItem windows -Recurse -File -Include *.cpp,*.h |
    Where-Object {
        $_.FullName -notmatch '[\\/](node_modules|target|dist)[\\/]'
    }
if ($cppFiles.Count -gt 0) {
    throw "Windows product must not restore the retired Qt/C++ implementation."
}

$tauriSource = (Resolve-Path windows/tauri/src).Path
$allowedDirectImports = @(
    (Join-Path $tauriSource "core/lithe-core-client.ts")
    (Join-Path $tauriSource "platform/tauri-core.ts")
)
$directImports = Get-ChildItem $tauriSource -Recurse -File -Include *.ts,*.tsx |
    Select-String -SimpleMatch -CaseSensitive 'from "@tauri-apps/api/core"' |
    Select-Object -ExpandProperty Path -Unique |
    Where-Object {
        $_ -notin $allowedDirectImports
    }
if ($directImports) {
    throw "Frontend modules must use @/platform/tauri-core: $($directImports -join ', ')"
}

$viteConfig = Get-Content windows/tauri/vite.config.ts -Raw
if ($viteConfig.Contains('src/mocks/tauri-api-mock')) {
    throw "Desktop builds must not alias Tauri APIs to browser mocks."
}

$cargo = Get-Content windows/tauri/src-tauri/Cargo.toml -Raw
if (-not $cargo.Contains('lithe-core = { path = "../../../rust/lithe-core" }')) {
    throw "Windows Tauri host must depend directly on the shared lithe-core crate."
}

$invokeBoundary = Get-Content windows/tauri/src/platform/tauri-core.ts -Raw
if (-not $invokeBoundary.Contains('capabilityForCommand(command)')) {
    throw "Windows invoke boundary must reject unavailable backend capabilities."
}

Write-Output "Windows React/Tauri boundaries verified."
