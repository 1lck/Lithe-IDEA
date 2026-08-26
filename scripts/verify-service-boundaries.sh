#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"
"$ROOT_DIR/scripts/verify-macos-app-build-safety.sh"

core_pattern='import (SwiftUI|AppKit|CoreServices)|\b(FileManager|UserDefaults|NSWorkspace|NSApp)\b|(^|[^A-Za-z])Process\(|(^|[^A-Za-z])Pipe\(|FileHandle'
service_pattern='import (SwiftUI|AppKit)|\b(FileManager|UserDefaults|NSWorkspace|NSApp)\b|(^|[^A-Za-z])Process\(|(^|[^A-Za-z])Pipe\(|FileHandle|String\(contentsOf:|Data\(contentsOf:|write\(to:.*encoding:|\bMac[A-Z][A-Za-z]+\b|/opt/homebrew|/usr/local|/usr/bin'
ui_service_pattern='\b(MavenService|JavaRunService|JavaDebugService|ProjectRuntimeService|GitService|WorkspaceSearchIndex)\b'
composition_pattern='\bMac[A-Z][A-Za-z]+\b'
application_ui_pattern='import AppKit|\b(NSOpenPanel|NSWorkspace|NSPasteboard|NSEvent)\b'
appmodel_business_pattern='Task\.detached|LocalHistoryService|WorkspaceTextFilePolicy|DirectoryChangeSource|fileOperations\.(fileExists|isDirectory|createFile|createDirectory|copyItem|moveItem|removeItem|trashItem|writeText)|mavenFeature\.loadProject|runFeature\.loadProject|configuration\.kind|debugFeature\.(startMaven|toggleBreakpoint|attachRemote)'
model_platform_pattern='\b(FileManager|UserDefaults|NSWorkspace|NSApp)\b|(^|[^A-Za-z])Process\(|(^|[^A-Za-z])Pipe\(|FileHandle'

core_violations=$(rg -n "$core_pattern" macos/Sources/Lithe/Core || true)
service_violations=$(rg -n "$service_pattern" macos/Sources/Lithe/Services || true)
ui_violations=$(rg -n "$ui_service_pattern" macos/Sources/Lithe/Views || true)
appmodel_path=macos/Sources/Lithe/Models/AppModel/AppModel.swift
composition_violations=$(rg -n "$composition_pattern" "$appmodel_path" || true)
application_ui_violations=$(rg -n "$application_ui_pattern" "$appmodel_path" || true)
appmodel_business_violations=$(rg -n "$appmodel_business_pattern" "$appmodel_path" || true)
model_platform_violations=$(rg -n "$model_platform_pattern" macos/Sources/Lithe/Models || true)
appmodel_line_count=$(wc -l < "$appmodel_path" | tr -d ' ')

if [[ -n "$core_violations" ]]; then
    print -u2 "Core boundary violations:"
    print -u2 "$core_violations"
    exit 1
fi

if [[ -n "$service_violations" ]]; then
    print -u2 "Service boundary violations:"
    print -u2 "$service_violations"
    exit 1
fi

if [[ -n "$ui_violations" ]]; then
    print -u2 "UI boundary violations:"
    print -u2 "$ui_violations"
    exit 1
fi

if [[ -n "$composition_violations" ]]; then
    print -u2 "AppModel composition violations:"
    print -u2 "$composition_violations"
    exit 1
fi

if [[ -n "$application_ui_violations" ]]; then
    print -u2 "AppModel platform UI violations:"
    print -u2 "$application_ui_violations"
    exit 1
fi

if [[ -n "$appmodel_business_violations" ]]; then
    print -u2 "AppModel business ownership violations:"
    print -u2 "$appmodel_business_violations"
    exit 1
fi

if [[ -n "$model_platform_violations" ]]; then
    print -u2 "Model platform boundary violations:"
    print -u2 "$model_platform_violations"
    exit 1
fi

if (( appmodel_line_count > 1800 )); then
    print -u2 "AppModel is too large for a UI-only aggregator: ${appmodel_line_count} lines"
    exit 1
fi

print "Service boundary verification passed: Core, Services, UI, and AppModel composition boundaries are intact"
