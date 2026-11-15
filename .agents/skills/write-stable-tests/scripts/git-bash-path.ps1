function Resolve-GitForWindowsTools {
    param([Parameter(Mandatory)][string]$GitPath)
    # Git for Windows can put git.exe in cmd, usr/bin, ucrt64/bin, or
    # mingw64/bin. Walk only its nearby ancestors and require both tools in
    # the same installation; an unrelated system/WSL bash is never selected.
    $candidate = Split-Path -Parent $GitPath
    for ($depth = 0; $depth -lt 4 -and -not [string]::IsNullOrEmpty($candidate); $depth++) {
        $bash = Join-Path $candidate "bin/bash.exe"
        $cygpath = Join-Path $candidate "usr/bin/cygpath.exe"
        if ((Test-Path -LiteralPath $bash -PathType Leaf) -and (Test-Path -LiteralPath $cygpath -PathType Leaf)) {
            return [pscustomobject]@{ Bash = $bash; Cygpath = $cygpath }
        }
        $parent = Split-Path -Parent $candidate
        if ($parent -eq $candidate) { break }
        $candidate = $parent
    }
    throw "Git for Windows Bash and cygpath were not found beside git.exe: $GitPath"
}
