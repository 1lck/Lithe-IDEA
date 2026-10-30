# Build-only preparation; no download, installation or published resource writes.
function Initialize-WindowsNativeBun {
    param([Parameter(Mandatory)][string]$RepositoryRoot, [string]$NativeBunPath = "")

    $candidates = @()
    if ($NativeBunPath) {
        $candidates = @($NativeBunPath)
    } else {
        $native = Get-Command bun.exe -CommandType Application -ErrorAction SilentlyContinue
        if ($native) { $candidates += $native.Source }
        # npm's PowerShell shim is runnable by PowerShell, but spawnSync cannot
        # execute it. Resolve the adjacent native package without running npm.
        $shim = Get-Command bun -ErrorAction SilentlyContinue
        if ($shim -and $shim.Source) {
            $candidates += Join-Path (Split-Path -Parent $shim.Source) "node_modules/bun/bin/bun.exe"
        }
        if ($env:BUN_INSTALL) { $candidates += Join-Path $env:BUN_INSTALL "bin/bun.exe" }
        $candidates += Join-Path ([Environment]::GetFolderPath("UserProfile")) ".bun/bin/bun.exe"
    }
    $executable = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $executable -or [IO.Path]::GetFileName($executable) -ne "bun.exe") {
        throw "A native bun.exe is required before resource verification; supply -NativeBunPath."
    }
    # PowerShell's location can differ from the native process working directory.
    $executable = (Get-Item -LiteralPath $executable).FullName
    $package = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot "windows/tauri/package.json") | ConvertFrom-Json
    $expected = ([string]$package.packageManager) -replace '^bun@', ''
    if (-not $expected -or $expected -eq $package.packageManager) { throw "packageManager must pin Bun." }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($executable)
    $process.StartInfo.WorkingDirectory = $RepositoryRoot
    $process.StartInfo.ArgumentList.Add("--version")
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $started = $false
    try {
        $started = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { throw "Native Bun version inspection exceeded 10 seconds." }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 2000)) {
            throw "Native Bun version output did not close within 2 seconds."
        }
        if ($process.ExitCode -ne 0 -or $stdout.Result.Trim() -ne $expected) {
            throw "Native Bun must match packageManager ($expected)."
        }
    } finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) { throw "Native Bun version process survived cleanup." }
            }
        } finally { $process.Dispose() }
    }
    # Establish this before Node cache verifiers and inherited install workers.
    $env:PATH = (Split-Path -Parent $executable) + [IO.Path]::PathSeparator + $env:PATH
}

function Invoke-TauriWithOriginalManifestBytes {
    param([Parameter(Mandatory)][string]$Manifest, [Parameter(Mandatory)][scriptblock]$Action)

    $original = [IO.File]::ReadAllBytes($Manifest)
    # Admit exactly CRLF -> LF, without decoding, TOML serialization or a
    # semantic hash. Every other byte remains part of the source identity.
    $lf = [Collections.Generic.List[byte]]::new()
    for ($index = 0; $index -lt $original.Length; $index++) {
        if ($original[$index] -eq 13 -and $index + 1 -lt $original.Length -and $original[$index + 1] -eq 10) { continue }
        $lf.Add($original[$index])
    }
    $originalKey = [Convert]::ToBase64String($original)
    $lfKey = [Convert]::ToBase64String($lf.ToArray())
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    $stream = $null
    try {
        # Compare and restore through one exclusive handle. Opening an existing
        # file fails on deletion or a conflicting owner rather than recreating
        # it or overwriting an edit between a separate read and write.
        $stream = [IO.File]::Open($Manifest, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $current = [byte[]]::new($stream.Length)
        $stream.ReadExactly($current, 0, $current.Length)
        $currentKey = [Convert]::ToBase64String($current)
        if ($currentKey -eq $originalKey) {
            # Leave unchanged bytes and file timestamps untouched.
        } elseif ($currentKey -eq $lfKey) {
            $stream.Position = 0
            $stream.Write($original, 0, $original.Length)
            $stream.SetLength($original.Length)
            $stream.Flush($true)
        } else {
            throw "Tauri changed Cargo.toml beyond the admitted CRLF-to-LF conversion; current bytes were preserved."
        }
    } catch {
        if ($null -ne $failure) {
            # Neither the action failure nor a later rejected restoration is
            # allowed to hide the other diagnostic.
            throw [AggregateException]::new("Tauri manifest check failed. Prior build failure: $($failure.Exception.Message)",
                [Exception[]]@($_.Exception, $failure.Exception))
        }
        throw
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if ($null -ne $failure) { throw $failure }
}
