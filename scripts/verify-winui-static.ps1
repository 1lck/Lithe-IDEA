[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$xamlPath = "windows/winui/MainWindow.xaml"
$headerPath = "windows/winui/MainWindow.xaml.h"
$sourcePath = "windows/winui/MainWindow.xaml.cpp"
$resourcesPath = "windows/winui/App.xaml"
$projectPath = "windows/winui/Lithe.WinUI.vcxproj"
$xaml = Get-Content -Raw -LiteralPath $xamlPath
$header = Get-Content -Raw -LiteralPath $headerPath
$source = Get-Content -Raw -LiteralPath $sourcePath
$resources = Get-Content -Raw -LiteralPath $resourcesPath
$project = Get-Content -Raw -LiteralPath $projectPath

$settings = New-Object System.Xml.XmlReaderSettings
$settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
$reader = [System.Xml.XmlReader]::Create($xamlPath, $settings)
try { [System.Xml.Linq.XDocument]::Load($reader) | Out-Null }
finally { $reader.Dispose() }
$reader = [System.Xml.XmlReader]::Create($resourcesPath, $settings)
try { [System.Xml.Linq.XDocument]::Load($reader) | Out-Null }
finally { $reader.Dispose() }
$reader = [System.Xml.XmlReader]::Create($projectPath, $settings)
try { [System.Xml.Linq.XDocument]::Load($reader) | Out-Null }
finally { $reader.Dispose() }

$eventNames = "Click|Tapped|DoubleTapped|RightTapped|PointerPressed|ItemClick|ItemInvoked|SelectionChanged|TextChanged|KeyDown|Loaded|SizeChanged|DragDelta|LostFocus|Checked|Unchecked|TabCloseRequested|Invoked"
$eventPattern = '(?:' + $eventNames + ')="([A-Za-z_][A-Za-z0-9_]*)"'
$handlers = [regex]::Matches($xaml, $eventPattern) |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach ($handler in $handlers) {
    if ($header -notmatch "\b$([regex]::Escape($handler))\s*\(") {
        throw "XAML handler is not declared: $handler"
    }
    if ($source -notmatch "MainWindow::$([regex]::Escape($handler))\s*\(") {
        throw "XAML handler is not defined: $handler"
    }
}

$resourceKeys = [regex]::Matches($xaml, '(?:StaticResource|ThemeResource) (Lithe[A-Za-z0-9_]+)') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach ($key in $resourceKeys) {
    if ($resources -notmatch ('x:Key="' + [regex]::Escape($key) + '"')) {
        throw "WinUI resource is not defined in App.xaml: $key"
    }
}

foreach ($component in @("ui_dialogs.h", "ui_dialogs.cpp")) {
    if (-not (Test-Path -LiteralPath "windows/winui/$component" -PathType Leaf)) {
        throw "WinUI component is missing: $component"
    }
    if ($project -notmatch ('Include="' + [regex]::Escape($component) + '"')) {
        throw "WinUI component is not included in the project: $component"
    }
}

$names = [regex]::Matches($xaml, 'x:Name="([A-Za-z_][A-Za-z0-9_]*)"') |
    ForEach-Object { $_.Groups[1].Value }
$duplicates = $names | Group-Object | Where-Object Count -gt 1
if ($duplicates) {
    throw "Duplicate WinUI x:Name values: $($duplicates.Name -join ', ')"
}

Write-Output "WinUI static verification passed ($($handlers.Count) handlers, $($resourceKeys.Count) Lithe resources)"
