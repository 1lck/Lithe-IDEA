[CmdletBinding()]
param(
    # Where the verified files land. Defaults to .artifacts/conpty, which is both
    # copied next to the executable by build.rs and packaged into the installer by
    # the bundle resources in tauri.conf.json. Keep it architecture independent so
    # the static configuration can point at it.
    [string]$OutputDirectory = "",
    # Windows platform key from third_party/conpty/manifest.json. Defaults to the
    # host architecture so a plain dev run stages the pair this machine can load.
    [string]$Platform = "",
    # Report a download or verification failure as a warning instead of failing the
    # caller. Used by the dev command so an offline machine can still start the app
    # with the system console host.
    [switch]$BestEffort
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

# Machines that installed PowerShell 7 can inherit a PSModulePath mixing both
# editions; Windows PowerShell 5.1 then auto-loads the PS 7 copy of
# Microsoft.PowerShell.Utility and loses cmdlets such as Get-FileHash. Drop the
# PS 7 module directories for this process only.
$env:PSModulePath = ((
    $env:PSModulePath -split ';' |
        Where-Object { $_ -and $_ -notmatch '(?i)powershell\\7\\Modules' }
) -join ';')

if ($BestEffort) {
    # Warnings must not abort the dev start; the build script reports the degraded
    # console host separately when the files are absent.
    $WarningPreference = "Continue"
}
$manifestPath = Join-Path $root "third_party/conpty/manifest.json"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Platform)) {
    $Platform = switch ($env:PROCESSOR_ARCHITECTURE) {
        "ARM64" { "windows-aarch64" }
        default { "windows-x86_64" }
    }
}
$platformInfo = $manifest.platforms.$Platform
if ($null -eq $platformInfo) {
    throw "ConPTY manifest has no entry for platform '$Platform'. Known platforms: $($manifest.platforms.PSObject.Properties.Name -join ', ')"
}
if ([string]::IsNullOrWhiteSpace([string]$platformInfo.conptyDLLSHA256) -or
    [string]::IsNullOrWhiteSpace([string]$platformInfo.openConsoleSHA256)) {
    throw "ConPTY manifest is missing checksums for platform '$Platform'."
}

$output = [System.IO.Path]::GetFullPath(
    $(if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        Join-Path $root ".artifacts/conpty"
    } else {
        $OutputDirectory
    })
)
$artifactsRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".artifacts"))
$artifactsPrefix = $artifactsRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
    [System.IO.Path]::DirectorySeparatorChar
if (-not $output.StartsWith($artifactsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ConPTY output must be inside the repository .artifacts directory: $output"
}

$cache = Join-Path $root ".artifacts/conpty-downloads"
$packageCache = Join-Path $cache ("Microsoft.Windows.Console.ConPTY." + $manifest.version + ".nupkg")
$packageHash = ([string]$manifest.packageSHA256).ToLowerInvariant()
$conptyHash = ([string]$platformInfo.conptyDLLSHA256).ToLowerInvariant()
$openConsoleHash = ([string]$platformInfo.openConsoleSHA256).ToLowerInvariant()

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
        if ((Get-FileSHA256 -Path $Destination) -eq $ExpectedSHA256) { return }
        Write-Warning "$Description cache checksum mismatch; re-downloading"
        Remove-Item -Force -LiteralPath $Destination
    }

    # Windows PowerShell 5.1 defaults to protocols that GitHub rejects, and the
    # failure surfaces as an opaque "connection closed" error. Ask for TLS 1.2
    # before the first request so the same script works on old and new hosts.
    try {
        $current = [Net.ServicePointManager]::SecurityProtocol
        if (($current -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
            [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
        }
    } catch {
        Write-Warning "Could not raise the TLS protocol for the download: $($_.Exception.Message)"
    }

    $temporaryPath = "$Destination.download-$PID"
    try {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -Force -LiteralPath $temporaryPath }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        Invoke-WebRequest -Uri $Uri -OutFile $temporaryPath
        $actualHash = Get-FileSHA256 -Path $temporaryPath
        if ($actualHash -ne $ExpectedSHA256) {
            throw "$Description checksum mismatch: expected $ExpectedSHA256, got $actualHash"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        Move-Item -Force -LiteralPath $temporaryPath -Destination $Destination
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -Force -LiteralPath $temporaryPath }
    }
}

function Get-ConptyFiles {
    Get-VerifiedDownload `
        -Uri ([string]$manifest.packageURL) `
        -ExpectedSHA256 $packageHash `
        -Destination $packageCache `
        -Description "Windows ConPTY package $($manifest.version)"

    # The package is a NuGet archive; the two files below are what a host needs at
    # runtime: conpty.dll exports CreatePseudoConsole and OpenConsole.exe is the
    # console host it launches.
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    $extractRoot = Join-Path $cache ("extract-" + $PID)
    if (Test-Path -LiteralPath $extractRoot) { Remove-Item -Recurse -Force -LiteralPath $extractRoot }
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

    try {
      Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($packageCache)
    try {
        foreach ($entry in @(
            @{ Entry = [string]$platformInfo.conptyDLL; Name = "conpty.dll"; Hash = $conptyHash },
            @{ Entry = [string]$platformInfo.openConsole; Name = "OpenConsole.exe"; Hash = $openConsoleHash }
        )) {
            $match = $archive.Entries | Where-Object { $_.FullName -eq $entry.Entry } | Select-Object -First 1
            if ($null -eq $match) {
                throw "ConPTY package $($manifest.version) has no entry '$($entry.Entry)'"
            }
            $destinationPath = Join-Path $output $entry.Name
            $temporaryPath = "$destinationPath.tmp-$PID"
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($match, $temporaryPath, $true)
            $actualHash = Get-FileSHA256 -Path $temporaryPath
            if ($actualHash -ne $entry.Hash) {
                Remove-Item -Force -LiteralPath $temporaryPath
                throw "ConPTY $($entry.Name) checksum mismatch: expected $($entry.Hash), got $actualHash"
            }
            Move-Item -Force -LiteralPath $temporaryPath -Destination $destinationPath
        }
    } finally {
        $archive.Dispose()
    }
    } finally {
        if (Test-Path -LiteralPath $extractRoot) { Remove-Item -Recurse -Force -LiteralPath $extractRoot }
    }

    # build.rs reads this to copy the files next to the executable it produces.
    # The license travels with them: the MIT text requires the copyright and
    # permission notice to accompany every distributed copy.
    $licenseSource = Join-Path $root "third_party/conpty/LICENSE.txt"
    if (-not (Test-Path -LiteralPath $licenseSource -PathType Leaf)) {
        throw "ConPTY license text is missing: $licenseSource"
    }
    Copy-Item -Force -LiteralPath $licenseSource -Destination (Join-Path $output "ConPTY-LICENSE.txt")

    $stamp = [ordered]@{
        version = [string]$manifest.version
        platform = $Platform
        conptyDLLSHA256 = $conptyHash
        openConsoleSHA256 = $openConsoleHash
    }
    $stamp | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath (Join-Path $output ".lithe-conpty.json")
}

try {
    Get-ConptyFiles
} catch {
    if (-not $BestEffort) { throw }
    Write-Warning "ConPTY runtime was not staged: $($_.Exception.Message). The terminal will use the system console host, which drops extended keyboard sequences such as Shift+Enter."
    exit 0
}

Write-Output $output
