#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

core_pattern='import (SwiftUI|AppKit|CoreServices)|\b(FileManager|UserDefaults|NSWorkspace|NSApp)\b|(^|[^A-Za-z])Process\(|(^|[^A-Za-z])Pipe\(|FileHandle'
service_pattern='import (SwiftUI|AppKit)|\b(FileManager|UserDefaults|NSWorkspace|NSApp)\b|(^|[^A-Za-z])Process\(|(^|[^A-Za-z])Pipe\(|FileHandle|String\(contentsOf:|Data\(contentsOf:|write\(to:.*encoding:|\bMac[A-Z][A-Za-z]+\b|/opt/homebrew|/usr/local|/usr/bin'
ui_service_pattern='\b(MavenService|JavaRunService|JavaDebugService|ProjectRuntimeService|JavaLanguageService|JavaImplementationMarkerService|GitService|WorkspaceSearchIndex)\b'
composition_pattern='\bMac[A-Z][A-Za-z]+\b'

core_violations=$(rg -n "$core_pattern" Sources/Lithe/Core || true)
service_violations=$(rg -n "$service_pattern" Sources/Lithe/Services || true)
ui_violations=$(rg -n "$ui_service_pattern" Sources/Lithe/Views || true)
composition_violations=$(rg -n "$composition_pattern" Sources/Lithe/Models/AppModel.swift || true)

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

print "Service boundary verification passed: Core, Services, UI, and AppModel composition boundaries are intact"
