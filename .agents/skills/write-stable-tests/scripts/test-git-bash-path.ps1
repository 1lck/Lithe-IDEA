$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "git-bash-path.ps1")
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("lithe git path " + [guid]::NewGuid().ToString("N"))
try {
    $root = Join-Path $fixture "Git installation"
    foreach ($folder in @("bin", "cmd", "usr/bin", "ucrt64/bin", "mingw64/bin")) {
        New-Item -ItemType Directory -Path (Join-Path $root $folder) -Force | Out-Null
    }
    foreach ($file in @("bin/bash.exe", "usr/bin/cygpath.exe", "cmd/git.exe", "usr/bin/git.exe", "ucrt64/bin/git.exe", "mingw64/bin/git.exe")) {
        New-Item -ItemType File -Path (Join-Path $root $file) -Force | Out-Null
    }
    foreach ($git in @("cmd/git.exe", "usr/bin/git.exe", "ucrt64/bin/git.exe", "mingw64/bin/git.exe")) {
        $tools = Resolve-GitForWindowsTools -GitPath (Join-Path $root $git)
        if ($tools.Bash -ne (Join-Path $root "bin/bash.exe") -or $tools.Cygpath -ne (Join-Path $root "usr/bin/cygpath.exe")) {
            throw "Unexpected tools for $git : $($tools | Out-String)"
        }
    }
    Remove-Item -LiteralPath (Join-Path $root "usr/bin/cygpath.exe")
    $rejected = $false
    try { Resolve-GitForWindowsTools -GitPath (Join-Path $root "cmd/git.exe") | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "A Git installation without cygpath was accepted" }
    Write-Output "Git Bash discovery tests passed."
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
