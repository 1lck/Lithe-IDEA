#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

xaml="windows/winui/MainWindow.xaml"
header="windows/winui/MainWindow.xaml.h"
source="windows/winui/MainWindow.xaml.cpp"
resources="windows/winui/App.xaml"
project="windows/winui/Lithe.WinUI.vcxproj"

[[ -f "$xaml" && -f "$header" && -f "$source" && -f "$resources" && -f "$project" ]] || {
    print -u2 "WinUI static inputs are incomplete"
    exit 1
}

# Catch malformed XML before a Windows XAML compiler is involved. xmllint is
# optional on macOS, so use Python's standard library when it is unavailable.
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$xaml" "$resources" "$project"
else
    python3 - "$xaml" "$resources" "$project" <<'PY'
import sys
import xml.etree.ElementTree as ET
for path in sys.argv[1:]:
    ET.parse(path)
PY
fi

# Every event declared in XAML must have both a declaration and a definition.
handlers=("${(@f)$(rg -o '(Click|Tapped|DoubleTapped|RightTapped|PointerPressed|ItemClick|ItemInvoked|SelectionChanged|TextChanged|KeyDown|Loaded|SizeChanged|DragDelta|LostFocus|Checked|Unchecked|TabCloseRequested|Invoked)="[A-Za-z_][A-Za-z0-9_]*"' "$xaml" | sed -E 's/.*="([A-Za-z_][A-Za-z0-9_]*)"/\1/' | sort -u)}")
for handler in $handlers; do
    rg -q "\b${handler}\s*\(" "$header" || {
        print -u2 "XAML handler is not declared: $handler"
        exit 1
    }
    rg -q "MainWindow::${handler}\s*\(" "$source" || {
        print -u2 "XAML handler is not defined: $handler"
        exit 1
    }
done

for component in ui_dialogs.h ui_dialogs.cpp; do
    [[ -f "windows/winui/$component" ]] || {
        print -u2 "WinUI component is missing: $component"
        exit 1
    }
    rg -q "Include=\"${component}\"" "$project" || {
        print -u2 "WinUI component is not included in the project: $component"
        exit 1
    }
done

# Resource names that belong to Lithe must be declared centrally. System
# resources are deliberately excluded from this check.
resourceKeys=("${(@f)$(rg -o '(StaticResource|ThemeResource) Lithe[A-Za-z0-9_]+' "$xaml" | sed -E 's/.* (Lithe[A-Za-z0-9_]+)/\1/' | sort -u)}")
for key in $resourceKeys; do
    rg -q "x:Key=\"${key}\"" "$resources" || {
        print -u2 "WinUI resource is not defined in App.xaml: $key"
        exit 1
    }
done

# Duplicate x:Name values are a frequent source of generated-code failures.
duplicates=$(rg -o 'x:Name="[A-Za-z_][A-Za-z0-9_]*"' "$xaml" \
    | sed -E 's/.*x:Name="([^"]+)"/\1/' | sort | uniq -d)
if [[ -n "$duplicates" ]]; then
    print -u2 "Duplicate WinUI x:Name values: $duplicates"
    exit 1
fi

print "WinUI static verification passed (${#handlers} handlers, ${#resourceKeys} Lithe resources)"
