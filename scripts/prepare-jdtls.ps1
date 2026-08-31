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
$archiveUsesOverride = -not [string]::IsNullOrWhiteSpace($env:LITHE_JDTLS_ARCHIVE)
$archiveHash = $manifest.archiveSHA256.ToLowerInvariant()
$licenseHash = $manifest.licenseSHA256.ToLowerInvariant()
$lombokHash = $manifest.lombokSHA256.ToLowerInvariant()
$lombokLicenseHash = $manifest.lombokLicenseSHA256.ToLowerInvariant()
$javaDebugArchiveHash = $manifest.javaDebugArchiveSHA256.ToLowerInvariant()
$javaDebugPluginHash = $manifest.javaDebugPluginSHA256.ToLowerInvariant()
$javaDebugLicenseHash = $manifest.javaDebugLicenseSHA256.ToLowerInvariant()
$safeVersion = ([string]$manifest.version) -replace '[^A-Za-z0-9._-]', '_'
$safeLombokVersion = ([string]$manifest.lombokVersion) -replace '[^A-Za-z0-9._-]', '_'
$safeJavaDebugExtensionVersion = ([string]$manifest.javaDebugExtensionVersion) -replace '[^A-Za-z0-9._-]', '_'
$safeJavaDebugServerVersion = ([string]$manifest.javaDebugServerVersion) -replace '[^A-Za-z0-9._-]', '_'
$archive = if ($archiveUsesOverride) {
    $env:LITHE_JDTLS_ARCHIVE
} else {
    Join-Path $cache "jdtls-$safeVersion-$archiveHash.tar.gz"
}
$license = Join-Path $cache "EPL-2.0-$licenseHash.txt"
$lombok = Join-Path $cache "lombok-$safeLombokVersion-$lombokHash.jar"
$lombokLicense = Join-Path $cache "lombok-MIT-$safeLombokVersion-$lombokLicenseHash.txt"
# Expand-Archive validates the file extension even though VSIX files are ZIP
# archives, so keep the verified payload under a compatible cache name.
$javaDebugArchive = Join-Path $cache "vscode-java-debug-$safeJavaDebugExtensionVersion-$javaDebugArchiveHash.zip"
$javaDebugLicense = Join-Path $cache "java-debug-EPL-1.0-$safeJavaDebugServerVersion-$javaDebugLicenseHash.txt"
$javaDebugPluginName = "com.microsoft.java.debug.plugin-$safeJavaDebugServerVersion.jar"

function Get-FileSHA256 {
    param([Parameter(Mandatory)][string]$Path)

    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-CacheWarning {
    param([Parameter(Mandatory)][string]$Message)

    Write-Warning $Message
    if ($env:GITHUB_ACTIONS -eq "true") {
        $escaped = $Message.Replace("%", "%25").Replace("`r", "%0D").Replace("`n", "%0A")
        Write-Output "::warning title=JDTLS cache fallback::$escaped"
    }
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
        Write-CacheWarning "$Description cache checksum mismatch; removing it before retrying the download"
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

function Assert-JdtlsOutput {
    if (-not (Test-Path -LiteralPath (Join-Path $output "plugins") -PathType Container)) { throw "JDTLS plugins directory is missing: $output" }
    $equinoxLauncher = Get-ChildItem -LiteralPath (Join-Path $output "plugins") -File -Filter "org.eclipse.equinox.launcher_*.jar" |
        Sort-Object Name | Select-Object -First 1
    if ($null -eq $equinoxLauncher) { throw "JDTLS Equinox launcher is missing: $output/plugins" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "config_mac") -PathType Container)) { throw "JDTLS macOS configuration is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "config_win") -PathType Container)) { throw "JDTLS Windows configuration is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "bin/jdtls.ps1") -PathType Leaf)) { throw "JDTLS PowerShell launcher is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "bin/jdtls.bat") -PathType Leaf)) { throw "JDTLS batch launcher is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "lombok/lombok.jar") -PathType Leaf)) { throw "JDTLS Lombok agent is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "lombok/LICENSE-MIT.txt") -PathType Leaf)) { throw "JDTLS Lombok license is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "java-debug/$javaDebugPluginName") -PathType Leaf)) { throw "Java Debug Server plugin is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "java-debug/LICENSE-EPL-1.0.txt") -PathType Leaf)) { throw "Java Debug Server license is missing: $output" }
    # Wrapper scripts remain for external/legacy launch plans. Packaged JDTLS
    # uses the direct-launch resources validated above.
    $launcher = Get-Content -Raw -LiteralPath (Join-Path $output "bin/jdtls.ps1")
    if (-not $launcher.Contains("-javaagent:")) { throw "JDTLS launcher does not load the Lombok agent: $output" }
}

if ($usesExistingRoot) {
    Assert-JdtlsOutput
    Write-Output $output
    exit 0
}

New-Item -ItemType Directory -Force -Path $cache | Out-Null
if ($archiveUsesOverride) {
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "JDTLS archive was not found: $archive" }
    $actualArchiveHash = Get-FileSHA256 -Path $archive
    if ($actualArchiveHash -ne $archiveHash) { throw "JDTLS archive checksum mismatch: expected $archiveHash, got $actualArchiveHash" }
} else {
    Get-VerifiedDownload -Uri $manifest.archiveURL -ExpectedSHA256 $archiveHash -Destination $archive -Description "JDTLS archive"
}
Get-VerifiedDownload -Uri $manifest.licenseURL -ExpectedSHA256 $licenseHash -Destination $license -Description "EPL-2.0 license"
Get-VerifiedDownload -Uri $manifest.lombokURL -ExpectedSHA256 $lombokHash -Destination $lombok -Description "Lombok agent"
Get-VerifiedDownload -Uri $manifest.lombokLicenseURL -ExpectedSHA256 $lombokLicenseHash -Destination $lombokLicense -Description "Lombok MIT license"
Get-VerifiedDownload -Uri $manifest.javaDebugArchiveURL -ExpectedSHA256 $javaDebugArchiveHash -Destination $javaDebugArchive -Description "Java Debug extension"
Get-VerifiedDownload -Uri $manifest.javaDebugLicenseURL -ExpectedSHA256 $javaDebugLicenseHash -Destination $javaDebugLicense -Description "Java Debug EPL-1.0 license"

if (Test-Path -LiteralPath $output) { Remove-Item -Recurse -Force -LiteralPath $output }
New-Item -ItemType Directory -Force -Path $output | Out-Null
tar.exe -xzf $archive -C $output
Copy-Item -LiteralPath $license -Destination (Join-Path $output "LICENSE-EPL-2.0.txt") -Force
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $output "manifest.json") -Force
$lombokOutput = Join-Path $output "lombok"
New-Item -ItemType Directory -Force -Path $lombokOutput | Out-Null
Copy-Item -LiteralPath $lombok -Destination (Join-Path $lombokOutput "lombok.jar") -Force
Copy-Item -LiteralPath $lombokLicense -Destination (Join-Path $lombokOutput "LICENSE-MIT.txt") -Force
$javaDebugOutput = Join-Path $output "java-debug"
New-Item -ItemType Directory -Force -Path $javaDebugOutput | Out-Null
$javaDebugExtraction = Join-Path $cache "java-debug-extract-$PID"
try {
    if (Test-Path -LiteralPath $javaDebugExtraction) { Remove-Item -Recurse -Force -LiteralPath $javaDebugExtraction }
    Expand-Archive -LiteralPath $javaDebugArchive -DestinationPath $javaDebugExtraction -Force
    $javaDebugPlugin = Join-Path $javaDebugExtraction "extension/server/$javaDebugPluginName"
    if (-not (Test-Path -LiteralPath $javaDebugPlugin -PathType Leaf)) { throw "Java Debug Server plugin was not found in the verified extension archive" }
    $actualJavaDebugPluginHash = Get-FileSHA256 -Path $javaDebugPlugin
    if ($actualJavaDebugPluginHash -ne $javaDebugPluginHash) {
        throw "Java Debug Server plugin checksum mismatch: expected $javaDebugPluginHash, got $actualJavaDebugPluginHash"
    }
    Copy-Item -LiteralPath $javaDebugPlugin -Destination (Join-Path $javaDebugOutput $javaDebugPluginName) -Force
} finally {
    if (Test-Path -LiteralPath $javaDebugExtraction) { Remove-Item -Recurse -Force -LiteralPath $javaDebugExtraction }
}
Copy-Item -LiteralPath $javaDebugLicense -Destination (Join-Path $javaDebugOutput "LICENSE-EPL-1.0.txt") -Force

$windowsLauncher = @'
$ErrorActionPreference = "Stop"
$javaExecutable = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin\java.exe" } else { "java" }
$lombokAgent = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\lombok\lombok.jar"))
if (-not (Test-Path -LiteralPath $lombokAgent -PathType Leaf)) { throw "JDTLS Lombok agent was not found: $lombokAgent" }
$jvmArguments = [System.Collections.Generic.List[string]]::new()
$jvmArguments.Add("-javaagent:$lombokAgent")
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
