[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$sourceFiles = Get-ChildItem -Path windows -Recurse -File |
    Where-Object {
        $_.Extension -in @(".h", ".hpp", ".cpp", ".cc", ".cxx") -and
        $_.FullName -notmatch "[\\/]build([\\/]|$)"
    }
if ($sourceFiles.Count -gt 0) {
    $macOSReference = Select-String -Path $sourceFiles.FullName `
        -Pattern "SwiftUI|AppKit|\.swift(?:$|[^A-Za-z0-9_])|MacOS|Mac[A-Z]" `
        -SimpleMatch:$false -CaseSensitive
    if ($null -ne $macOSReference) {
        $macOSReference | Format-Table -AutoSize | Out-String | Write-Error
        throw "Windows source must not reference the macOS application"
    }
}

$publicHeaders = Get-ChildItem -Path windows/adapters, windows/core, windows/qt `
    -Filter *.h -File -ErrorAction SilentlyContinue
if ($publicHeaders.Count -gt 0) {
    $nativeLeak = Select-String -Path $publicHeaders.FullName `
        -Pattern "\b(HANDLE|HPCON)\b|#include\s+<windows\.h>|#include\s+<winconpty\.h>"
    if ($null -ne $nativeLeak) {
        $nativeLeak | Format-Table -AutoSize | Out-String | Write-Error
        throw "Windows public ports must not expose Win32 handle types"
    }
}

$required = @(
    "windows/core/core_client.cpp",
    "windows/core/core_worker_pool.cpp",
    "windows/adapters/win32_file_system.cpp",
    "windows/adapters/win32_file_storage.cpp",
    "windows/adapters/win32_directory_watcher.cpp",
    "windows/adapters/win32_process_session.cpp",
    "windows/adapters/win32_process_runner.cpp",
    "windows/adapters/win32_terminal_transport.cpp",
    "windows/adapters/win32_http_transport.cpp",
    "windows/adapters/win32_runtime_locator.cpp",
    "windows/adapters/win32_secure_store.cpp",
    "windows/adapters/win32_authenticode_verifier.cpp",
    "windows/adapters/win32_key_value_store.cpp",
    "windows/app/services/ai_commit_service.cpp",
    "windows/app/services/windows_update_service.cpp",
    "windows/packaging/update_helper.cpp",
    "windows/qt/workbench_code_editor.cpp",
    "windows/qt/workbench_window.cpp"
)
foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing Windows implementation: $file"
    }
}

$algorithmFiles = Get-ChildItem -Path windows/app/algorithms -Recurse -File `
    -ErrorAction SilentlyContinue
if ($algorithmFiles.Count -gt 0) {
    $forbiddenAlgorithmDependency = Select-String -Path $algorithmFiles.FullName `
        -Pattern '#include\s*[<"](windows\.h|Qt[A-Za-z0-9_/.-]*)'
    if ($null -ne $forbiddenAlgorithmDependency) {
        throw "windows/app/algorithms must not depend on Win32 or Qt"
    }
}

$serviceFiles = Get-ChildItem -Path windows/app/services -Recurse -File `
    -ErrorAction SilentlyContinue
if ($serviceFiles.Count -gt 0) {
    $forbiddenServiceDependency = Select-String -Path $serviceFiles.FullName `
        -Pattern '#include\s*[<"](windows\.h|Qt[A-Za-z0-9_/.-]*)'
    if ($null -ne $forbiddenServiceDependency) {
        throw "windows/app/services must not depend on Win32 or Qt"
    }
}

$qtFiles = Get-ChildItem -Path windows/qt -Recurse -File `
    | Where-Object { $_.Extension -in @(".h", ".cpp", ".hpp") }
if ($qtFiles.Count -gt 0) {
    $directCoreClientIncludes = Select-String -Path $qtFiles.FullName `
        -Pattern '#include\s*[<"]core_client\.h[>"]'
    if ($null -ne $directCoreClientIncludes) {
        $directCoreClientIncludes | Format-Table -AutoSize | Out-String | Write-Error
        throw "Qt code must not include core_client.h directly"
    }
}

Write-Output "Windows boundary verification passed"
