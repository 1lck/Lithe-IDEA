$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$testOutput = Join-Path $root "dist/updater-manifest-test"
$version = "9.8.7"
$bundle = Join-Path $testOutput "Lithe-$version-windows-x64-updater.exe"

try {
    New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
    Set-Content -LiteralPath $bundle -Value "test updater bundle" -Encoding ascii
    Set-Content -LiteralPath "$bundle.sig" -Value "test-signature" -Encoding ascii

    & "$PSScriptRoot/create-windows-updater-manifest.ps1" `
        -Version $version `
        -Repository "example/Lithe-IDEA" `
        -ReleaseTag "v$version" `
        -OutputDirectory "dist/updater-manifest-test"

    $manifest = Get-Content -LiteralPath (Join-Path $testOutput "latest.json") -Raw |
        ConvertFrom-Json
    if ($manifest.version -ne $version) { throw "Manifest version is incorrect" }
    $platform = $manifest.platforms.'windows-x86_64'
    if ($platform.signature -ne "test-signature") { throw "Manifest signature is incorrect" }
$expectedURL = "https://github.com/example/Lithe-IDEA/releases/download/v$version/Lithe-$version-windows-x64-updater.exe"
    if ($platform.url -ne $expectedURL) { throw "Manifest download URL is incorrect" }

    Write-Output "Windows updater manifest test passed."
} finally {
    if (Test-Path -LiteralPath $testOutput) {
        Remove-Item -LiteralPath $testOutput -Recurse -Force
    }
}
