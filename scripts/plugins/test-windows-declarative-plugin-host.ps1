[CmdletBinding()]
param(
    [ValidateSet("x86_64-pc-windows-msvc")]
    [string]$RustTarget = "x86_64-pc-windows-msvc",
    [switch]$SkipBuild,
    [switch]$ResumeBuild,
    [string]$ResourceSource = "",
    [string]$NativeBunPath = "",
    # Per install attempt (one clean retry); retains the installer default.
    [ValidateRange(1, 1200)][int]$InstallTimeoutSeconds = 300,
    [switch]$Marketplace,
    [switch]$LspLifecycle,
    [switch]$SettingsFunctions,
    [string]$SettingsFunctionsFixtureRoot = "",
    [switch]$TextWindow,
    [string]$MarketplaceFixtureRoot = "",
    [string]$MarketplaceTlsCert = "",
    [string]$MarketplaceTlsKey = "",
    [string]$MarketplaceListenHost = "127.0.0.1"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "The declarative plugin host acceptance requires Windows." }
if ($SkipBuild -and $ResumeBuild) { throw "Choose either -SkipBuild or -ResumeBuild." }
if ($SettingsFunctions -ne (-not [string]::IsNullOrWhiteSpace($SettingsFunctionsFixtureRoot))) {
    throw "Use -SettingsFunctions and -SettingsFunctionsFixtureRoot together (generate settings_functions_fixture.py inputs first)."
}
if ($SettingsFunctions -and ($Marketplace -or $LspLifecycle)) {
    throw "Settings/functions is a focused invocation; run marketplace/LSP acceptance separately."
}
if ($SettingsFunctions -and -not $SkipBuild) {
    throw "Settings/functions consumes an existing isolated host: use -SkipBuild to preserve its generated inputs and build identity."
}
if ($TextWindow -and ($Marketplace -or $LspLifecycle -or $SettingsFunctions)) {
    throw "Text-window acceptance is a focused invocation; run marketplace/LSP/settings acceptance separately."
}
$controlledMarketplaceArguments = @($MarketplaceFixtureRoot, $MarketplaceTlsCert, $MarketplaceTlsKey)
$providedMarketplaceArguments = @($controlledMarketplaceArguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($providedMarketplaceArguments.Count -gt 0 -and (-not $Marketplace -or $providedMarketplaceArguments.Count -ne 3)) {
    throw "Controlled marketplace acceptance requires -Marketplace, -MarketplaceFixtureRoot, -MarketplaceTlsCert and -MarketplaceTlsKey together."
}

$root = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$artifactParent = [IO.Path]::GetFullPath((Join-Path $root ".artifacts"))
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $artifactParent "plugin-host-acceptance"))
$stabilityRoot = [IO.Path]::GetFullPath((Join-Path $artifactParent "test-stability"))
$fixtureRoot = Join-Path $root "scripts/plugins/host-acceptance"
$profileRoot = [IO.Path]::GetFullPath(
    (Join-Path $root "windows/tauri/src-tauri/target/$RustTarget/release")
)
$sourceExecutable = Join-Path $profileRoot "lithe-windows.exe"
$identityMarker = Join-Path $artifactRoot "build-identity.json"
$customConfig = Join-Path $artifactRoot "tauri.host-acceptance.conf.json"
$acceptanceIdentifier = "app.lithe.windows.host-acceptance"

function Assert-OwnedPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $resolved = [IO.Path]::GetFullPath($Path)
    $resolvedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to manage a path outside $Parent`: $resolved"
    }
}

function Reset-OwnedDirectory {
    param([Parameter(Mandatory)][string]$Path)
    Assert-OwnedPath -Path $Path -Parent $artifactParent
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (exit $LASTEXITCODE)" }
}

function Invoke-BoundedDriver {
    param([string[]]$Arguments, [string]$LogPath, [int]$TimeoutSeconds = 900)
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command python).Source)
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $driver = [Diagnostics.Process]::new()
    $driver.StartInfo = $startInfo
    $started = $false
    try {
        $started = $driver.Start()
        $stdout = $driver.StandardOutput.ReadToEndAsync()
        $stderr = $driver.StandardError.ReadToEndAsync()
        if (-not $driver.WaitForExit($TimeoutSeconds * 1000)) {
            throw "The native acceptance driver exceeded its $TimeoutSeconds second deadline."
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) {
            throw "The native acceptance driver output did not close within 5 seconds."
        }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $output | Set-Content -LiteralPath $LogPath -Encoding utf8NoBOM
        Write-Host $output
        return $driver.ExitCode
    } finally {
        try {
            if ($started -and -not $driver.HasExited) {
                $driver.Kill($true)
                if (-not $driver.WaitForExit(5000)) { throw "The acceptance driver survived bounded cleanup." }
            }
        } finally {
            $driver.Dispose()
        }
    }
}

function Write-NormalizedReport {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Details
    )
    @{
        runner = "acceptance"
        warnMs = 1000
        maxMs = 15000
        tests = @(@{
            name = $Name
            suite = "plugin-host-acceptance / source-guard"
            status = $Status
            durationMs = 0
            maxMs = 15000
            details = $Details
        })
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Save-TextWindowSourceInventory {
    param([Parameter(Mandatory)][string]$Path)
    $code = "import sys,json,pathlib; sys.path.insert(0,sys.argv[1]); from text_window_fixture import source_inventory; pathlib.Path(sys.argv[2]).write_text(json.dumps(source_inventory(),sort_keys=True),encoding='utf-8')"
    $result = Invoke-BoundedDriver -Arguments @("-B", "-c", $code, $fixtureRoot, $Path) `
        -LogPath (Join-Path $artifactRoot "text-window-source-inventory.log") -TimeoutSeconds 330
    if ($result -ne 0) { throw "The complete text-window source inventory failed." }
}

function Assert-TextWindowSourceInventory {
    param([Parameter(Mandatory)][string]$Path, [switch]$Identity)
    # Compare dictionaries in Python, independent of PowerShell property order.
    # A legacy marker without an inventory must never be upgraded after building.
    $code = @'
import sys,json,pathlib
sys.path.insert(0,sys.argv[1])
from text_window_fixture import source_inventory
expected=json.loads(pathlib.Path(sys.argv[2]).read_text(encoding='utf-8-sig'))
expected=expected.get('sourceInventory') if sys.argv[3]=='identity' else expected
current=source_inventory()
if not isinstance(expected,dict) or expected!=current:
    raise ValueError('text-window build source inventory is missing or changed')
'@
    $kind = if ($Identity) { "identity" } else { "inventory" }
    $result = Invoke-BoundedDriver -Arguments @("-B", "-c", $code, $fixtureRoot, $Path, $kind) `
        -LogPath (Join-Path $artifactRoot "text-window-source-identity-check.log") -TimeoutSeconds 330
    if ($result -ne 0) { throw "The text-window build source inventory is missing or changed." }
}

function Stop-OwnedAcceptanceProcesses {
    param([Parameter(Mandatory)][string]$StagedExecutable)
    $executablePath = [IO.Path]::GetFullPath($StagedExecutable)
    # Share the driver's upstream native inspector. Full CIM enumeration can
    # hang on an unrelated process even when every owned process has exited.
    $inventoryPath = Join-Path $evidenceRoot "wrapper-process-inventory.json"
    $inventoryCode = "import sys,json,pathlib; sys.path.insert(0,sys.argv[1]); import acceptance_driver as d; print(json.dumps(d.acceptance_process_inventory(pathlib.Path(sys.argv[2]),sys.argv[3]),ensure_ascii=True))"
    $inventoryExit = Invoke-BoundedDriver -Arguments @(
        "-B", "-c", $inventoryCode, $fixtureRoot, $executablePath, $acceptanceIdentifier
    ) -LogPath $inventoryPath -TimeoutSeconds 15
    if ($inventoryExit -ne 0) { throw "Could not inspect acceptance-owned processes; see $inventoryPath" }
    $snapshot = @(Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json)
    $survivors = @($snapshot | Where-Object {
        ($_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -eq $executablePath) -or
        ($_.CommandLine -and
            $_.CommandLine.Contains("fake-lsp-server.mjs", [StringComparison]::OrdinalIgnoreCase) -and
            $_.CommandLine.Contains($acceptanceIdentifier, [StringComparison]::OrdinalIgnoreCase))
    })
    # Retain kernel handles before terminating anything. A PID from a CIM
    # snapshot is never sufficient authority to kill a later process.
    $owners = [Collections.Generic.List[Diagnostics.Process]]::new()
    $pending = [Collections.Generic.Queue[object]]::new()
    foreach ($record in $survivors) { $pending.Enqueue($record) }
    $seen = @{}
    try {
        while ($pending.Count -gt 0) {
            $record = $pending.Dequeue()
            $processId = [int]$record.ProcessId
            if ($seen.ContainsKey($processId)) { continue }
            $seen[$processId] = $true
            $owner = $null
            $retained = $false
            try {
                $owner = [Diagnostics.Process]::GetProcessById($processId)
                $null = $owner.Handle
                if ($owner.HasExited) { continue }
                $created = [int64]$record.CreationTime
                $actualCreated = $owner.StartTime.ToUniversalTime().ToFileTimeUtc()
                if ($created -ne $actualCreated) { continue }
                if (-not $record.ExecutablePath -or
                    [IO.Path]::GetFullPath($owner.MainModule.FileName) -ne [IO.Path]::GetFullPath($record.ExecutablePath)) { continue }
                $owners.Add($owner)
                $retained = $true
                foreach ($child in $snapshot) {
                    if ($child.ParentProcessId -eq $processId -and $child.CreationTime -ge $record.CreationTime) {
                        $pending.Enqueue($child)
                    }
                }
            } catch [ArgumentException] {
                # The original process exited before its handle was captured.
            } catch [InvalidOperationException] {
                # The retained process exited during inspection.
            } finally {
                if ($null -ne $owner -and -not $retained) { $owner.Dispose() }
            }
        }
        foreach ($owner in $owners) {
            if (-not $owner.HasExited) { $owner.Kill() }
        }
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        foreach ($owner in $owners) {
            $remainingMs = [Math]::Max(0, 5000 - [int]$deadline.ElapsedMilliseconds)
            if (-not $owner.WaitForExit($remainingMs)) {
                throw "Acceptance-owned process survived cleanup: $($owner.Id)"
            }
        }
    } finally {
        foreach ($owner in $owners) { $owner.Dispose() }
    }
    return $survivors
}

New-Item -ItemType Directory -Path $artifactParent -Force | Out-Null
New-Item -ItemType Directory -Path $stabilityRoot -Force | Out-Null
if (-not $SkipBuild -and -not $ResumeBuild) {
    Reset-OwnedDirectory -Path $artifactRoot
} else {
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    if ($SkipBuild -and -not (Test-Path -LiteralPath $identityMarker -PathType Leaf)) {
        throw "-SkipBuild requires the prior isolated build identity marker: $identityMarker"
    }
    if ($ResumeBuild -and -not (Test-Path -LiteralPath (Join-Path $artifactRoot "release-build.log") -PathType Leaf)) {
        throw "-ResumeBuild requires evidence that this lane already attempted its formal Release build."
    }
    if ($SkipBuild) {
        $priorIdentity = Get-Content -LiteralPath $identityMarker -Raw | ConvertFrom-Json
        if ($priorIdentity.identifier -ne $acceptanceIdentifier -or
            $priorIdentity.rustTarget -ne $RustTarget -or
            $priorIdentity.gitRevision -ne (& git -C $root rev-parse HEAD).Trim() -or
            -not (Test-Path -LiteralPath $customConfig -PathType Leaf) -or
            $priorIdentity.configSha256 -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $customConfig).Hash.ToLowerInvariant() -or
            $priorIdentity.executableSha256 -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceExecutable).Hash.ToLowerInvariant()) {
            throw "The prior executable, source revision or config no longer matches its isolated application identity marker."
        }
        Assert-TextWindowSourceInventory -Path $identityMarker -Identity
    }
}

$runImage = Join-Path $artifactRoot "run-image"
$packages = Join-Path $artifactRoot "packages"
$workspaces = Join-Path $artifactRoot "workspaces"
$runtimeRoot = Join-Path $artifactRoot "runtime"
$evidenceRoot = Join-Path $artifactRoot "evidence"
foreach ($directory in @($runImage, $packages, $workspaces, $runtimeRoot, $evidenceRoot)) {
    Reset-OwnedDirectory -Path $directory
}

if (-not $SkipBuild) {
    @{
        '$schema' = "https://schema.tauri.app/config/2"
        productName = "Lithe Host Acceptance"
        identifier = $acceptanceIdentifier
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $customConfig -Encoding utf8NoBOM
}

Invoke-NativeChecked -Executable "node" -Arguments @("--check", (Join-Path $fixtureRoot "fake-lsp-server.mjs")) `
    -FailureMessage "The controlled language-server fixture has invalid JavaScript"
Invoke-NativeChecked -Executable "python" -Arguments @("-B", "-c", "import playwright,psutil") `
    -FailureMessage "Install acceptance dependencies with python -m pip install playwright==1.60.0 psutil==7.2.2"
Invoke-NativeChecked -Executable "python" -Arguments @(
    "-B",
    "-c",
    "import ast,pathlib; [ast.parse(pathlib.Path(p).read_text(encoding='utf-8')) for p in __import__('sys').argv[1:]]",
    (Join-Path $fixtureRoot "acceptance_driver.py"),
    (Join-Path $fixtureRoot "acceptance_driver_test.py"),
    (Join-Path $fixtureRoot "build_preflight_test.py"),
    (Join-Path $fixtureRoot "marketplace_acceptance.py"),
    (Join-Path $fixtureRoot "marketplace_acceptance_test.py"),
    (Join-Path $fixtureRoot "lsp_lifecycle_acceptance.py"),
    (Join-Path $fixtureRoot "lsp_lifecycle_acceptance_test.py"),
    (Join-Path $fixtureRoot "marketplace_fixture.py"),
    (Join-Path $fixtureRoot "generate_packages.py"),
    (Join-Path $fixtureRoot "settings_functions_fixture.py"),
    (Join-Path $fixtureRoot "settings_functions_acceptance.py"),
    (Join-Path $fixtureRoot "settings_functions_acceptance_test.py"),
    (Join-Path $fixtureRoot "text_window_fixture.py"),
    (Join-Path $fixtureRoot "text_window_acceptance.py"),
    (Join-Path $fixtureRoot "text_window_acceptance_test.py")
) -FailureMessage "A plugin host acceptance Python source file has invalid syntax"

& (Join-Path $root ".agents/skills/write-stable-tests/scripts/verify-test-stability.ps1") -Platform windows
if ($LASTEXITCODE -ne 0) { throw "The Windows stable-test source guard failed." }
& (Join-Path $root "scripts/windows/verify/verify-windows-boundaries.ps1")
if ($LASTEXITCODE -ne 0) { throw "The Windows architecture boundary verification failed." }

$driverUnitReport = Join-Path $stabilityRoot "plugin-host-acceptance-driver.json"
Invoke-NativeChecked -Executable "python" -Arguments @(
    "-B",
    (Join-Path $fixtureRoot "acceptance_driver_test.py"),
    "--report", $driverUnitReport
) -FailureMessage "The acceptance process-owner unit checks failed"

$preflightExit = Invoke-BoundedDriver -Arguments @(
    "-B", (Join-Path $fixtureRoot "build_preflight_test.py"),
    "--report", (Join-Path $stabilityRoot "plugin-build-preflight.json")
) -LogPath (Join-Path $artifactRoot "build-preflight-tests.log") -TimeoutSeconds 190
if ($preflightExit -ne 0) { throw "The offline build preparation checks failed." }

Invoke-NativeChecked -Executable "python" -Arguments @(
    "-B",
    (Join-Path $fixtureRoot "marketplace_acceptance_test.py"),
    "--report", (Join-Path $stabilityRoot "plugin-marketplace-acceptance-driver.json")
) -FailureMessage "The marketplace fixture and locator unit checks failed"

Invoke-NativeChecked -Executable "python" -Arguments @(
    "-B",
    (Join-Path $fixtureRoot "lsp_lifecycle_acceptance_test.py"),
    "--report", (Join-Path $stabilityRoot "plugin-lsp-lifecycle-driver.json")
) -FailureMessage "The LSP lifecycle event and initialization gate unit checks failed"

Invoke-NativeChecked -Executable "python" -Arguments @(
    "-B", (Join-Path $fixtureRoot "settings_functions_acceptance_test.py"),
    "--report", (Join-Path $stabilityRoot "plugin-settings-functions-driver.json")
) -FailureMessage "The settings/functions acceptance self-checks failed"
if ($TextWindow) {
    Invoke-NativeChecked -Executable "python" -Arguments @(
        "-B", (Join-Path $fixtureRoot "text_window_acceptance_test.py"),
        "--report", (Join-Path $stabilityRoot "plugin-text-window-helpers.json")
    ) -FailureMessage "The literal text-window helper checks failed"
}

$zsh = Get-Command zsh -ErrorAction SilentlyContinue
$immutabilityReport = Join-Path $stabilityRoot "plugin-host-acceptance-source-guard.json"
if ($null -eq $zsh) {
    Write-NormalizedReport -Path $immutabilityReport `
        -Name "original runtime bundle immutability source guard" `
        -Status "skipped" `
        -Details "zsh is unavailable on this Windows host; scripts/macos/verify/verify-runtime-bundle-immutability.sh remains pending and no substitute scan is labeled runtime acceptance."
} else {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    # MSYS zsh does not normalize a native drive prefix in $0 before its :A
    # expansion. A relative entry preserves the guard's root on SUBST drives.
    Push-Location $root
    try {
        & $zsh.Source "./scripts/macos/verify/verify-runtime-bundle-immutability.sh"
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) { throw "The original runtime bundle immutability source guard failed." }
    Write-NormalizedReport -Path $immutabilityReport `
        -Name "original runtime bundle immutability source guard" `
        -Status "passed" `
        -Details "scripts/macos/verify/verify-runtime-bundle-immutability.sh completed through zsh in $($timer.ElapsedMilliseconds) ms."
}

if (-not $SkipBuild) {
    # Only presence is needed here; avoid a full CIM inventory whose unrelated
    # process properties can fail before the build even starts.
    $heavyProcesses = @(Get-Process -Name cargo, rustc -ErrorAction SilentlyContinue)
    if ($heavyProcesses.Count -gt 0) {
        throw "Refusing to overlap the formal Release build with existing Cargo/Rust processes: $($heavyProcesses.Id -join ', ')"
    }

    . (Join-Path $root "scripts/windows/build/windows-build-preflight.ps1")
    Initialize-WindowsNativeBun -RepositoryRoot $root -NativeBunPath $NativeBunPath

    if (-not [string]::IsNullOrWhiteSpace($ResourceSource)) {
        $resourceSourcePath = [IO.Path]::GetFullPath($ResourceSource)
        if (-not (Test-Path -LiteralPath $resourceSourcePath -PathType Container)) {
            throw "Resource source does not exist: $resourceSourcePath"
        }
        Invoke-NativeChecked -Executable "node" -Arguments @(
            (Join-Path $root "scripts/resources/reuse-worktree-resources.mjs"),
            "--source", $resourceSourcePath
        ) -FailureMessage "Worktree resource reuse failed"
    }

    $previousCargoJobs = $env:CARGO_BUILD_JOBS
    $previousToolchain = $env:RUSTUP_TOOLCHAIN
    $previousConpty = $env:LITHE_REQUIRE_CONPTY
    $transcriptStarted = $false
    $sourceInventoryBefore = Join-Path $artifactRoot "text-window-source-before.json"
    Save-TextWindowSourceInventory -Path $sourceInventoryBefore
    try {
        $env:CARGO_BUILD_JOBS = "2"
        $env:RUSTUP_TOOLCHAIN = "stable-$RustTarget"
        $env:LITHE_REQUIRE_CONPTY = "1"
        $buildLogName = if ($ResumeBuild) { "release-resume.log" } else { "release-build.log" }
        Start-Transcript -LiteralPath (Join-Path $artifactRoot $buildLogName) -Force | Out-Null
        $transcriptStarted = $true

        # This is deliberately the only formal Release build invocation in the lane.
        if (-not $ResumeBuild) {
            & (Join-Path $root "scripts/windows/build/build-windows.ps1") -Configuration Release -RustTarget $RustTarget -InstallTimeoutSeconds $InstallTimeoutSeconds
            if ($LASTEXITCODE -ne 0) { throw "The formal Windows Release build failed." }
        } else {
            Push-Location (Join-Path $root "windows/tauri")
            try {
                Invoke-NativeChecked -Executable "bun" -Arguments @("run", "typecheck") `
                    -FailureMessage "The resumed Windows frontend type check failed"
            } finally {
                Pop-Location
            }
        }

        $tauriArguments = @(
            "tauri", "build", "--no-bundle",
            "--config", "src-tauri/tauri.windows.conf.json",
            "--config", "src-tauri/tauri.jdtls.conf.json",
            "--config", $customConfig,
            "--target", $RustTarget
        )
        & (Join-Path $root "scripts/windows/build/invoke-windows-tauri-build.ps1") `
            -TauriArguments $tauriArguments `
            -FailureMessage "The incremental host-acceptance identity link failed"
        if ($LASTEXITCODE -ne 0) { throw "The incremental host-acceptance identity link failed." }

        if (-not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf)) {
            throw "The isolated Windows executable was not produced: $sourceExecutable"
        }
        $buildIdentity = @{
            identifier = $acceptanceIdentifier
            rustTarget = $RustTarget
            sourceExecutable = $sourceExecutable
            gitRevision = (& git -C $root rev-parse HEAD).Trim()
            configSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $customConfig).Hash.ToLowerInvariant()
            executableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceExecutable).Hash.ToLowerInvariant()
        }
        Assert-TextWindowSourceInventory -Path $sourceInventoryBefore
        $buildIdentity.sourceInventory = Get-Content -LiteralPath $sourceInventoryBefore -Raw | ConvertFrom-Json
        $buildIdentity | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $identityMarker -Encoding utf8NoBOM
    } finally {
        if ($transcriptStarted) { Stop-Transcript | Out-Null }
        $env:CARGO_BUILD_JOBS = $previousCargoJobs
        $env:RUSTUP_TOOLCHAIN = $previousToolchain
        $env:LITHE_REQUIRE_CONPTY = $previousConpty
    }
}

if (-not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf)) {
    throw "The custom-identity Release executable is missing: $sourceExecutable"
}

$stagedExecutable = Join-Path $runImage "lithe-host-acceptance.exe"
Copy-Item -LiteralPath $sourceExecutable -Destination $stagedExecutable -Force
$resourceNames = @(
    "extensions",
    "OfficialPlugins",
    "LanguageServers",
    "helpers",
    "conpty.dll",
    "OpenConsole.exe",
    "ConPTY-LICENSE.txt"
)
foreach ($resourceName in $resourceNames) {
    $source = Join-Path $profileRoot $resourceName
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $runImage $resourceName) -Recurse -Force
    }
}

# A resumed build may have been interrupted before build-windows.ps1 staged
# resources. Populate the run image from the same immutable build inputs.
$fallbackResources = [ordered]@{
    "extensions/bundled" = (Join-Path $root "windows/tauri/src/extensions/bundled")
    "OfficialPlugins/PhpSupportContract" = (Join-Path $root "Plugins/win/Official/PhpSupportContract")
    "LanguageServers/jdtls" = (Join-Path $artifactParent "jdtls")
    "LanguageServers/jdk" = (Join-Path $artifactParent "jdk")
    "helpers" = (Join-Path $root "windows/tauri/src-tauri/helpers")
    "conpty.dll" = (Join-Path $artifactParent "conpty/conpty.dll")
    "OpenConsole.exe" = (Join-Path $artifactParent "conpty/OpenConsole.exe")
    "ConPTY-LICENSE.txt" = (Join-Path $artifactParent "conpty/ConPTY-LICENSE.txt")
}
foreach ($resource in $fallbackResources.GetEnumerator()) {
    $destination = Join-Path $runImage $resource.Key
    if (-not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $resource.Value)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $resource.Value -Destination $destination -Recurse -Force
    }
}
foreach ($required in @(
    $stagedExecutable,
    (Join-Path $runImage "extensions/bundled"),
    (Join-Path $runImage "OfficialPlugins"),
    (Join-Path $runImage "LanguageServers/jdtls"),
    (Join-Path $runImage "LanguageServers/jdk/bin/java.exe"),
    (Join-Path $runImage "conpty.dll"),
    (Join-Path $runImage "OpenConsole.exe")
)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "The staged run image is incomplete: $required" }
}

Invoke-NativeChecked -Executable "python" -Arguments @(
    "-B",
    (Join-Path $fixtureRoot "generate_packages.py"),
    "--output", $packages,
    "--server", (Join-Path $fixtureRoot "fake-lsp-server.mjs")
) -FailureMessage "The deterministic plugin packages could not be generated"

$workspaceOne = Join-Path $workspaces "one"
$workspaceTwo = Join-Path $workspaces "two"
New-Item -ItemType Directory -Path $workspaceOne, $workspaceTwo -Force | Out-Null
Set-Content -LiteralPath (Join-Path $workspaceOne "acceptance.litheaccept") -Value "workspace one" -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $workspaceOne "uninstall.litheaccept") -Value "uninstall workflow" -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $workspaceTwo "acceptance.litheaccept") -Value "workspace two" -Encoding utf8NoBOM

$appLocalData = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) $acceptanceIdentifier
$appRoamingData = Join-Path ([Environment]::GetFolderPath("ApplicationData")) $acceptanceIdentifier
$webviewData = Join-Path $runtimeRoot "webview2"
$acceptanceReport = Join-Path $stabilityRoot "plugin-host-acceptance.json"
$driverLog = Join-Path $artifactRoot "acceptance-driver.log"
if ($TextWindow) {
    $acceptanceReport = Join-Path $stabilityRoot "plugin-text-window-acceptance.json"
    $driverLog = Join-Path $artifactRoot "text-window-driver.log"
}

@{
    schemaVersion = 1
    identifier = $acceptanceIdentifier
    gitRevision = (& git -C $root rev-parse HEAD).Trim()
    rustTarget = $RustTarget
    osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    executable = $stagedExecutable
    executableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedExecutable).Hash.ToLowerInvariant()
    runImage = $runImage
    resourceNames = @($resourceNames | Where-Object { Test-Path -LiteralPath (Join-Path $runImage $_) })
    appLocalData = $appLocalData
    appRoamingData = $appRoamingData
    webviewData = $webviewData
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $artifactRoot "metadata.json") -Encoding utf8NoBOM

$driverExit = 1
$cleanupFailure = $null
try {
    $driverArguments = @(
        "-B", (Join-Path $fixtureRoot "acceptance_driver.py"),
        "--executable", $stagedExecutable,
        "--run-image", $runImage,
        "--artifact-root", $evidenceRoot,
        "--report", $acceptanceReport,
        "--app-local-data", $appLocalData,
        "--app-roaming-data", $appRoamingData,
        "--webview-data", $webviewData,
        "--package-v1-a", (Join-Path $packages "host-acceptance-1.0.0-a.zip"),
        "--package-v1-b", (Join-Path $packages "host-acceptance-1.0.0-b.zip"),
        "--package-v2", (Join-Path $packages "host-acceptance-1.1.0.zip"),
        "--workspace-one", $workspaceOne,
        "--workspace-two", $workspaceTwo
    )
    if ($Marketplace) { $driverArguments += "--marketplace" }
    if ($LspLifecycle) { $driverArguments += "--lsp-lifecycle" }
    if ($SettingsFunctions) {
        $driverArguments += @(
            "--settings-functions-fixture-root", ([IO.Path]::GetFullPath($SettingsFunctionsFixtureRoot)),
            "--settings-functions-host-identity", $identityMarker
        )
    }
    if ($providedMarketplaceArguments.Count -eq 3) {
        $driverArguments += @(
            "--marketplace-fixture-root", ([IO.Path]::GetFullPath($MarketplaceFixtureRoot)),
            "--marketplace-tls-cert", ([IO.Path]::GetFullPath($MarketplaceTlsCert)),
            "--marketplace-tls-key", ([IO.Path]::GetFullPath($MarketplaceTlsKey)),
            "--marketplace-listen-host", $MarketplaceListenHost
        )
    }
    if ($TextWindow) {
        $driverArguments = @(
            "-B", (Join-Path $fixtureRoot "text_window_acceptance.py"),
            "--fixture-root", (Join-Path $artifactRoot ("text-window-fixture-" + [guid]::NewGuid().ToString("N"))),
            "--host-identity", $identityMarker,
            "--executable", $stagedExecutable,
            "--run-image", $runImage,
            "--artifact-root", (Join-Path $evidenceRoot "text-window"),
            "--report", $acceptanceReport,
            "--app-local-data", $appLocalData,
            "--app-roaming-data", $appRoamingData,
            "--webview-data", $webviewData
        )
    }
    $driverExit = Invoke-BoundedDriver -LogPath $driverLog -Arguments $driverArguments
} catch {
    $driverFailure = $_.ToString()
    Write-NormalizedReport -Path $acceptanceReport -Name "native acceptance driver deadline or startup" `
        -Status "failed" -Details $driverFailure
    throw
} finally {
    try {
        $forced = @(Stop-OwnedAcceptanceProcesses -StagedExecutable $stagedExecutable)
        if ($forced.Count -gt 0) {
            $cleanupFailure = "The wrapper had to terminate acceptance-owned process IDs: $($forced.ProcessId -join ', ')"
        }
    } catch {
        $cleanupFailure = $_.ToString()
    }
    foreach ($isolatedData in @($appLocalData, $appRoamingData)) {
        $resolvedData = [IO.Path]::GetFullPath($isolatedData)
        if ([IO.Path]::GetFileName($resolvedData) -ne $acceptanceIdentifier) {
            $cleanupFailure = "Refusing cleanup of a non-acceptance data directory: $resolvedData"
            continue
        }
        if (Test-Path -LiteralPath $resolvedData) {
            try {
                $dataEvidence = Join-Path $evidenceRoot ("wrapper-cleanup-" + [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($resolvedData)))
                New-Item -ItemType Directory -Path $dataEvidence -Force | Out-Null
                foreach ($evidenceName in @("logs", "plugins", "plugin-state", "plugin-temp", "settings.json")) {
                    $evidenceSource = Join-Path $resolvedData $evidenceName
                    if (Test-Path -LiteralPath $evidenceSource) {
                        Copy-Item -LiteralPath $evidenceSource -Destination (Join-Path $dataEvidence $evidenceName) -Recurse -Force
                    }
                }
                Remove-Item -LiteralPath $resolvedData -Recurse -Force
            } catch {
                $cleanupFailure = $_.ToString()
            }
        }
    }
    & node (Join-Path $root ".agents/skills/write-stable-tests/scripts/generate-test-report.mjs") `
        --input-dir $stabilityRoot
    if ($LASTEXITCODE -ne 0 -and $null -eq $cleanupFailure) {
        $cleanupFailure = "Test stability report generation failed."
    }
}

if ($null -ne $cleanupFailure) { throw $cleanupFailure }
if ($driverExit -ne 0) { throw "The native Windows declarative plugin host acceptance failed (exit $driverExit)." }
Write-Output "Windows declarative plugin host acceptance passed; reports are in $stabilityRoot."
