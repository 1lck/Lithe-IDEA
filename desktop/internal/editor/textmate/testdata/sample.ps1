<#
.SYNOPSIS
  A block comment.
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Name = "world",
    [int] $Count = 0x1F
)
# A comment
function Get-Greeting {
    [CmdletBinding()]
    param([string] $Who)
    return "Hello, $Who! $($Count + 1)`n"
}
$items = @(1, 2, 3) | Where-Object { $_ -gt 1 }
if ($items.Count -ge 2 -and $null -ne $Name) {
    Write-Host 'single $quoted' -ForegroundColor Green
}
$env:PATH += ";C:\tools"
