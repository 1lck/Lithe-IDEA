# scripts/probe-lithe.ps1
# 用途：启动 Lithe.exe，等待窗口出现，检查错误日志，然后干净退出。
# 用法：.\scripts\probe-lithe.ps1 [-WaitSeconds 15] [-Iterations 1]
param(
    [int]$WaitSeconds = 15,
    [int]$Iterations = 1
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$candidates = @(
    (Join-Path $root "windows\build-winui\x64\Release\Lithe.exe"),
    (Join-Path $root "windows\winui\x64\Release\Lithe.WinUI\Lithe.exe")
)
$exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { throw "Lithe.exe not found; looked in: $($candidates -join ', ')" }

$logDir = Join-Path $env:TEMP "lithe-probe-logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

for ($i = 1; $i -le $Iterations; $i++) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logFile = Join-Path $logDir "lithe-$stamp-$i.log"
    Write-Host "[probe $i/$Iterations] starting Lithe..."
    $proc = Start-Process -FilePath $exe -PassThru -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err"
    $idle = 0
    while (-not $proc.HasExited -and $idle -lt $WaitSeconds) {
        Start-Sleep -Seconds 1
        $idle++
        $proc.Refresh()
    }
    if ($proc.HasExited) {
        Write-Host "[probe $i/$Iterations] FAIL: exited early with code $($proc.ExitCode)" -ForegroundColor Red
        exit 1
    }
    # 错误日志检查：应用自身写入的错误日志
    $appLog = ""
    if ($env:LOCALAPPDATA) { $appLog = Join-Path $env:LOCALAPPDATA "Lithe\lithe-winui-error.log" }
    if ($appLog -and (Test-Path $appLog)) {
        $size = (Get-Item $appLog).Length
        if ($size -gt 0) {
            Write-Host "[probe $i/$Iterations] FAIL: error log not empty ($size bytes)" -ForegroundColor Red
            Get-Content $appLog -Tail 30
            exit 1
        }
    }
    Write-Host "[probe $i/$Iterations] OK: alive after ${idle}s, closing..."
    $proc.CloseMainWindow() | Out-Null
    if (-not $proc.WaitForExit(5000)) { $proc.Kill() }
    Start-Sleep -Seconds 2
}
Write-Host "Probe passed ($Iterations iterations)"
