[CmdletBinding()]
param(
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root "third_party/jdtls/manifest.json"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$usesExistingRoot = [string]::IsNullOrWhiteSpace($OutputDirectory) -and
    -not [string]::IsNullOrWhiteSpace($env:LITHE_JDTLS_ROOT)
$requestedOutput = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    if ($usesExistingRoot) { $env:LITHE_JDTLS_ROOT } else { Join-Path $root ".artifacts/jdtls" }
} else {
    $OutputDirectory
}
$output = [System.IO.Path]::GetFullPath($requestedOutput)
$artifactsRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".artifacts"))
$artifactsPrefix = $artifactsRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $usesExistingRoot -and
    -not $output.StartsWith($artifactsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "JDTLS output must be inside the repository .artifacts directory: $output"
}
$cache = Join-Path $root ".artifacts/jdtls-downloads"
$archive = if ([string]::IsNullOrWhiteSpace($env:LITHE_JDTLS_ARCHIVE)) { Join-Path $cache "jdtls.tar.gz" } else { $env:LITHE_JDTLS_ARCHIVE }
$license = Join-Path $cache "EPL-2.0.txt"

function Assert-JdtlsOutput {
    if (-not (Test-Path -LiteralPath (Join-Path $output "plugins") -PathType Container)) { throw "JDTLS plugins directory is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "config_win") -PathType Container)) { throw "JDTLS Windows configuration is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "bin/jdtls.ps1") -PathType Leaf)) { throw "JDTLS PowerShell launcher is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "bin/jdtls.bat") -PathType Leaf)) { throw "JDTLS batch launcher is missing: $output" }
}

if ($usesExistingRoot) {
    Assert-JdtlsOutput
    Write-Output $output
    exit 0
}

New-Item -ItemType Directory -Force -Path $cache | Out-Null
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { Invoke-WebRequest -Uri $manifest.archiveURL -OutFile $archive }
$actualArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
if ($actualArchiveHash -ne $manifest.archiveSHA256.ToLowerInvariant()) { throw "JDTLS archive checksum mismatch: expected $($manifest.archiveSHA256), got $actualArchiveHash" }
if (-not (Test-Path -LiteralPath $license -PathType Leaf)) { Invoke-WebRequest -Uri $manifest.licenseURL -OutFile $license }
$actualLicenseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $license).Hash.ToLowerInvariant()
if ($actualLicenseHash -ne $manifest.licenseSHA256.ToLowerInvariant()) { throw "JDTLS license checksum mismatch: expected $($manifest.licenseSHA256), got $actualLicenseHash" }

if (Test-Path -LiteralPath $output) { Remove-Item -Recurse -Force -LiteralPath $output }
New-Item -ItemType Directory -Force -Path $output | Out-Null
tar.exe -xzf $archive -C $output
Copy-Item -LiteralPath $license -Destination (Join-Path $output "LICENSE-EPL-2.0.txt") -Force

$windowsLauncher = @'
$ErrorActionPreference = "Stop"
$javaExecutable = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin\java.exe" } else { "java" }
$jvmArguments = [System.Collections.Generic.List[string]]::new()
$jvmArguments.Add("--add-modules=ALL-SYSTEM")
$jvmArguments.Add("--add-opens=java.base/java.util=ALL-UNNAMED")
$jvmArguments.Add("--add-opens=java.base/java.lang=ALL-UNNAMED")
$serverArguments = [System.Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $args.Count; $index++) {
    $argument = [string]$args[$index]
    if ($argument -eq "--java-executable") { if ($index + 1 -ge $args.Count) { throw "--java-executable requires a path" }; $javaExecutable = [string]$args[++$index] }
    elseif ($argument.StartsWith("--jvm-arg=")) { $jvmArguments.Add($argument.Substring("--jvm-arg=".Length)) }
    elseif ($argument -eq "--jvm-arg") { if ($index + 1 -ge $args.Count) { throw "--jvm-arg requires a value" }; $jvmArguments.Add([string]$args[++$index]) }
    else { $serverArguments.Add($argument) }
}
$launcherJar = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "..\plugins") -Filter "org.eclipse.equinox.launcher_*.jar" | Sort-Object Name | Select-Object -First 1
if ($null -eq $launcherJar) { throw "JDTLS Equinox launcher was not found" }
$configuration = Join-Path $PSScriptRoot "..\config_win"
& $javaExecutable @jvmArguments "-Declipse.application=org.eclipse.jdt.ls.core.id1" "-Declipse.product=org.eclipse.jdt.ls.core.product" "-Dosgi.bundles.defaultStartLevel=4" "-Dlog.protocol=true" "-Dlog.level=ALL" "-jar" $launcherJar.FullName "-configuration" $configuration @serverArguments
exit $LASTEXITCODE
'@
Set-Content -LiteralPath (Join-Path $output "bin/jdtls.ps1") -Value $windowsLauncher -Encoding ascii

$batchLauncher = "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0jdtls.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
Set-Content -LiteralPath (Join-Path $output "bin/jdtls.bat") -Value $batchLauncher -Encoding ascii
Assert-JdtlsOutput
Write-Output $output
