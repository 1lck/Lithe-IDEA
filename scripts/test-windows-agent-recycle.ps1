[CmdletBinding()]
param([ValidateRange(15, 1200)][int]$BuildTimeoutSeconds = 600)

# Opt-in native acceptance: never empty the user's Recycle Bin. The driver owns
# one unique workspace and restores only entries whose original parent is it.
$ErrorActionPreference = "Stop"
if (-not $IsWindows) { throw "This acceptance requires an interactive Windows session." }
$root = Split-Path -Parent $PSScriptRoot
$reportRoot = Join-Path $root ".artifacts/test-stability/windows-agent-recycle"
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null

function Invoke-BoundedProcess([string]$Executable, [string[]]$Arguments, [int]$TimeoutMs) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($Executable)
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            throw "Native acceptance process exceeded $TimeoutMs ms."
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) {
            throw "Native acceptance output did not close within 5 seconds."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $diagnostics = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$output`n$diagnostics" }
        return $output
    } finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) { throw "Native acceptance process survived cleanup." }
            }
        } finally {
            $process.Dispose()
        }
    }
}

$compiled = Invoke-BoundedProcess "cargo" @("test", "--manifest-path", "windows/tauri/src-tauri/Cargo.toml", "--package", "lithe-project", "--lib", "--no-run", "--message-format=json") ($BuildTimeoutSeconds * 1000)
$binary = @($compiled -split "`n" | ForEach-Object { if ($_.Trim()) { $_ | ConvertFrom-Json } } | Where-Object {
    $_.reason -eq "compiler-artifact" -and $_.profile.test -and $_.executable -and $_.target.name -eq "lithe_project"
} | Select-Object -ExpandProperty executable)
if ($binary.Count -ne 1) { throw "Expected one lithe-project unit-test binary." }

$workspace = Join-Path ([IO.Path]::GetTempPath()) ("lithe-agent-recycle-acceptance-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workspace | Out-Null
$previousRoot = $env:LITHE_AGENT_RECYCLE_ACCEPTANCE_ROOT
$env:LITHE_AGENT_RECYCLE_ACCEPTANCE_ROOT = $workspace
$shell = $null
$bin = $null
$timer = [Diagnostics.Stopwatch]::StartNew()
$outcome = "passed"
$details = ""
try {
    $shell = New-Object -ComObject Shell.Application
    $bin = $shell.NameSpace(10)
    if ($null -eq $bin) { throw "The Windows Recycle Bin namespace is unavailable." }
    Invoke-BoundedProcess $binary[0] @("document_file::tests::agent_recycle_real_shell_acceptance", "--exact", "--ignored", "--nocapture") 15000 |
        Set-Content -LiteralPath (Join-Path $reportRoot "native.log") -Encoding utf8
    $owned = @($bin.Items() | Where-Object { $_.ExtendedProperty("System.Recycle.DeletedFrom") -eq $workspace })
    if ($owned.Count -ne 1) { throw "Expected exactly one recoverable fixture in the real Recycle Bin." }
    if ([IO.File]::ReadAllText($owned[0].Path) -ne "agent recycle acceptance") { throw "Recycled fixture bytes changed." }
    $details = "Verbatim workspace path recycled by SHFileOperationW; one real Recycle Bin entry retained the expected bytes."
} catch {
    $outcome = "failed"
    $details = $_.ToString()
    throw
} finally {
    try {
        $owned = if ($bin) { @($bin.Items() | Where-Object { $_.ExtendedProperty("System.Recycle.DeletedFrom") -eq $workspace }) } else { @() }
        foreach ($item in $owned) {
            $restoreName = $item.Name
            $recycledPath = $item.Path
            $item.InvokeVerb("undelete")
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            # Shell verbs complete asynchronously; poll the owned native entry,
            # with a local deadline, rather than assuming a delay means success.
            while (Test-Path -LiteralPath $recycledPath) {
                if ($deadline.ElapsedMilliseconds -ge 10000) { throw "Fixture restore exceeded 10 seconds: $restoreName" }
                Start-Sleep -Milliseconds 25
            }
            $restored = @(Get-ChildItem -LiteralPath $workspace -File -Force)
            if (-not @($restored | Where-Object { [IO.File]::ReadAllText($_.FullName) -eq "agent recycle acceptance" }).Count) {
                throw "The fixture was not restored before cleanup."
            }
        }
        $resolved = [IO.Path]::GetFullPath($workspace)
        if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or
            -not [IO.Path]::GetFileName($resolved).StartsWith("lithe-agent-recycle-acceptance-")) {
            throw "Refusing cleanup outside the owned temporary workspace."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } catch {
        $outcome = "failed"
        $details += " Cleanup: $($_.ToString()); workspace: $workspace"
        throw
    } finally {
        $env:LITHE_AGENT_RECYCLE_ACCEPTANCE_ROOT = $previousRoot
        if ($bin) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($bin) | Out-Null }
        if ($shell) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
        @{ schemaVersion = 1; runner = "rust"; package = "lithe-project-native-shell"; warnMs = 5000; maxMs = 30000;
            tests = @(@{ name = "agent_recycle_real_shell_acceptance"; target = "lithe-project"; status = $outcome; durationMs = $timer.ElapsedMilliseconds; details = $details })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $reportRoot "acceptance.json") -Encoding utf8NoBOM
        & node (Join-Path $root ".agents/skills/write-stable-tests/scripts/generate-test-report.mjs") --input-dir $reportRoot
        if ($LASTEXITCODE -ne 0) { throw "Native acceptance report generation failed." }
    }
}
Write-Output "Windows Agent Recycle Bin acceptance passed; fixture restored and cleaned."
