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
$javaTestArchiveHash = $manifest.javaTestArchiveSHA256.ToLowerInvariant()
$javaTestPluginHash = $manifest.javaTestPluginSHA256.ToLowerInvariant()
$javaTestRunnerHash = $manifest.javaTestRunnerSHA256.ToLowerInvariant()
$javaTestLicenseHash = $manifest.javaTestLicenseSHA256.ToLowerInvariant()
$safeVersion = ([string]$manifest.version) -replace '[^A-Za-z0-9._-]', '_'
$safeLombokVersion = ([string]$manifest.lombokVersion) -replace '[^A-Za-z0-9._-]', '_'
$safeJavaDebugExtensionVersion = ([string]$manifest.javaDebugExtensionVersion) -replace '[^A-Za-z0-9._-]', '_'
$safeJavaDebugServerVersion = ([string]$manifest.javaDebugServerVersion) -replace '[^A-Za-z0-9._-]', '_'
$safeJavaTestExtensionVersion = ([string]$manifest.javaTestExtensionVersion) -replace '[^A-Za-z0-9._-]', '_'
$safeJavaTestPluginVersion = ([string]$manifest.javaTestPluginVersion) -replace '[^A-Za-z0-9._-]', '_'

# JDT LS refuses to start on a Java runtime older than it requires, and the
# bundled JDK is the runtime Lithe launches it with.
$jdkManifest = Get-Content -Raw -LiteralPath (Join-Path $root "third_party/jdk/manifest.json") | ConvertFrom-Json
$bundledJdkMajor = [int](([string]$jdkManifest.version).Split(".")[0])
if ($bundledJdkMajor -lt [int]$manifest.minimumJavaVersion) {
    throw "Bundled JDK $($jdkManifest.version) is older than the Java $($manifest.minimumJavaVersion) that JDTLS $($manifest.version) requires"
}
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
$javaTestArchive = Join-Path $cache "vscode-java-test-$safeJavaTestExtensionVersion-$javaTestArchiveHash.zip"
$javaTestLicense = Join-Path $cache "java-test-MIT-$safeJavaTestExtensionVersion-$javaTestLicenseHash.txt"
$javaTestPluginName = "com.microsoft.java.test.plugin-$safeJavaTestPluginVersion.jar"
$javaTestRunnerName = "com.microsoft.java.test.runner-jar-with-dependencies.jar"
# Records the Java Test bundle set declared by the extension so validation
# checks the exact upstream list instead of a hard-coded count.
$javaTestBundleList = "java-test/extensions.txt"

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
    $javaTestExtensions = Join-Path $output "java-test/extensions"
    if (-not (Test-Path -LiteralPath (Join-Path $javaTestExtensions $javaTestPluginName) -PathType Leaf)) { throw "Java Test extension plugin is missing: $output" }
    $bundleListPath = Join-Path $output $javaTestBundleList
    if (-not (Test-Path -LiteralPath $bundleListPath -PathType Leaf)) { throw "Java Test bundle list is missing: $bundleListPath" }
    $declaredBundles = @(Get-Content -LiteralPath $bundleListPath | Where-Object { $_ -ne "" })
    foreach ($declaredBundle in $declaredBundles) {
        if (-not (Test-Path -LiteralPath (Join-Path $javaTestExtensions $declaredBundle) -PathType Leaf)) { throw "Java Test bundle $declaredBundle is missing: $javaTestExtensions" }
        if (Test-Path -LiteralPath (Join-Path $output "plugins/$declaredBundle")) { throw "Java Test bundle $declaredBundle duplicates a JDTLS plugin: $(Join-Path $output 'plugins')" }
    }
    $presentBundles = @(Get-ChildItem -LiteralPath $javaTestExtensions -File -Filter "*.jar")
    if ($presentBundles.Count -ne $declaredBundles.Count) { throw "Java Test extension bundles do not match ${javaTestBundleList}: $javaTestExtensions" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "java-test/runner/$javaTestRunnerName") -PathType Leaf)) { throw "Java Test runner is missing: $output" }
    if (-not (Test-Path -LiteralPath (Join-Path $output "java-test/LICENSE-MIT.txt") -PathType Leaf)) { throw "Java Test license is missing: $output" }
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
Get-VerifiedDownload -Uri $manifest.javaTestArchiveURL -ExpectedSHA256 $javaTestArchiveHash -Destination $javaTestArchive -Description "Java Test extension"
Get-VerifiedDownload -Uri $manifest.javaTestLicenseURL -ExpectedSHA256 $javaTestLicenseHash -Destination $javaTestLicense -Description "Java Test MIT license"

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
$javaTestOutput = Join-Path $output "java-test"
$javaTestExtensionsOutput = Join-Path $javaTestOutput "extensions"
$javaTestRunnerOutput = Join-Path $javaTestOutput "runner"
New-Item -ItemType Directory -Force -Path $javaTestExtensionsOutput, $javaTestRunnerOutput | Out-Null
$javaTestExtraction = Join-Path $cache "java-test-extract-$PID"
try {
    if (Test-Path -LiteralPath $javaTestExtraction) { Remove-Item -Recurse -Force -LiteralPath $javaTestExtraction }
    Expand-Archive -LiteralPath $javaTestArchive -DestinationPath $javaTestExtraction -Force
    $javaTestPackage = Get-Content -Raw -LiteralPath (Join-Path $javaTestExtraction "extension/package.json") | ConvertFrom-Json
    # The extension's `contributes.javaExtensions` is the upstream list of
    # bundles JDT LS must load; copying that list keeps the runner and coverage
    # agent out of OSGi and follows upstream when the set changes. Bundles JDT LS
    # already ships (Eclipse names them `<symbolic-name>_<version>.jar`) are
    # skipped: JDT LS cannot replace its own copy, so loading them only fails
    # with "A bundle is already installed" at every start.
    $declaredBundles = @($javaTestPackage.contributes.javaExtensions)
    if ($declaredBundles.Count -eq 0) { throw "Java Test extension declares no JDT LS bundles" }
    $bundleNames = [System.Collections.Generic.List[string]]::new()
    foreach ($declaredBundle in $declaredBundles) {
        $bundleSource = Join-Path (Join-Path $javaTestExtraction "extension") ([string]$declaredBundle).TrimStart(".", "/")
        $bundleName = Split-Path -Leaf $bundleSource
        if (Test-Path -LiteralPath (Join-Path $output "plugins/$bundleName")) { continue }
        Copy-Item -LiteralPath $bundleSource -Destination (Join-Path $javaTestExtensionsOutput $bundleName) -Force
        $bundleNames.Add($bundleName)
    }
    Set-Content -LiteralPath (Join-Path $output $javaTestBundleList) -Value $bundleNames -Encoding ascii
    Copy-Item -LiteralPath (Join-Path $javaTestExtraction "extension/server/$javaTestRunnerName") -Destination (Join-Path $javaTestRunnerOutput $javaTestRunnerName) -Force
} finally {
    if (Test-Path -LiteralPath $javaTestExtraction) { Remove-Item -Recurse -Force -LiteralPath $javaTestExtraction }
}
$actualJavaTestPluginHash = Get-FileSHA256 -Path (Join-Path $javaTestExtensionsOutput $javaTestPluginName)
if ($actualJavaTestPluginHash -ne $javaTestPluginHash) {
    throw "Java Test plugin checksum mismatch: expected $javaTestPluginHash, got $actualJavaTestPluginHash"
}
$actualJavaTestRunnerHash = Get-FileSHA256 -Path (Join-Path $javaTestRunnerOutput $javaTestRunnerName)
if ($actualJavaTestRunnerHash -ne $javaTestRunnerHash) {
    throw "Java Test runner checksum mismatch: expected $javaTestRunnerHash, got $actualJavaTestRunnerHash"
}
Copy-Item -LiteralPath $javaTestLicense -Destination (Join-Path $javaTestOutput "LICENSE-MIT.txt") -Force

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
