#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

module_ids=(workspace git search localHistory languageIntelligence execution debug terminal database aiAssistance)
module_types=(WorkspaceFoundation Database Git Search History LanguageIntelligence Execution Debug Terminal AIAssistance)
module_targets=(LitheWorkspaceModule LitheDatabaseModule LitheGitModule LitheSearchModule LitheLocalHistoryModule LitheLanguageIntelligenceModule LitheExecutionModule LitheDebugModule LitheTerminalModule LitheAIAssistanceModule)

for id in "${module_ids[@]}"; do
    if ! rg -q "static let ${id} = ModuleID" macos/Sources/LitheModuleAPI/Lifecycle/ModuleTypes.swift; then
        print -u2 "Missing built-in module ID: ${id}"
        exit 1
    fi
done

for index in {1..${#module_types[@]}}; do
    type="${module_types[$index]}"
    target="${module_targets[$index]}"
    if ! rg -q "(final|open) class ${type}Module" "macos/Sources/${target}"; then
        print -u2 "Missing module implementation: ${type}Module"
        exit 1
    fi
    if ! rg -q "name: \"${target}\"" Package.swift; then
        print -u2 "Missing SwiftPM module target: ${target}"
        exit 1
    fi
    if ! rg -q "${type}Module\.moduleManifest" macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift; then
        print -u2 "Missing composition registration: ${type}Module"
        exit 1
    fi
done

for contribution_type in Database Git Search History LanguageIntelligence Execution Debug Terminal AIAssistance; do
    if ! rg -q "${contribution_type}Module\.moduleContributions" macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift; then
        print -u2 "Missing lazy contribution registration: ${contribution_type}Module"
        exit 1
    fi
done

if ! rg -q '^import LitheAIAssistanceModule$' macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift; then
    print -u2 "AI Assistance must remain statically composed as an internal module"
    exit 1
fi
if rg -n 'AIAssistancePluginEntrypoint|dev\.lithe\.plugin\.ai-assistance' macos/Sources Plugins; then
    print -u2 "AI Assistance must not be exposed as a downloadable native plugin"
    exit 1
fi

rg -q 'Contents/Resources/OfficialPlugins' scripts/package-app.sh || {
    print -u2 "Packaged official plugins must use the signed resources package root"
    exit 1
}
if rg -n 'Contents/PlugIns' scripts/package-app.sh scripts/preview.sh; then
    print -u2 "Static plugin package directories must not be placed directly in Contents/PlugIns"
    exit 1
fi

if rg -n "final class (WorkspaceFoundation|Database|Git|Search|History|LanguageIntelligence|Execution|Debug|Terminal|AIAssistance)Module" macos/Sources/Lithe; then
    print -u2 "Module lifecycle implementation leaked back into the executable target"
    exit 1
fi

if rg -n "(terminalFactory|shellDiscovery|commitMessageGenerator)" macos/Sources/Lithe/Application/Composition/AppServices.swift; then
    print -u2 "Lazy module-owned factories leaked into AppServices"
    exit 1
fi

for legacy_terminal_file in \
    macos/Sources/Lithe/Application/TerminalFeatureModel.swift \
    macos/Sources/Lithe/Services/TerminalSession.swift \
    macos/Sources/Lithe/Services/TerminalLinkResolver.swift \
    macos/Sources/Lithe/Core/Ports/TerminalTransport.swift; do
    if [[ -e "$legacy_terminal_file" ]]; then
        print -u2 "Terminal implementation leaked outside LitheTerminalModule: $legacy_terminal_file"
        exit 1
    fi
done

for terminal_type in TerminalFeatureModel TerminalSession TerminalTransport TerminalLinkResolver; do
    rg -q "(class|protocol|enum) ${terminal_type}" macos/Sources/LitheTerminalModule || {
        print -u2 "Terminal module is missing real implementation: ${terminal_type}"
        exit 1
    }
done

for legacy_ai_file in \
    macos/Sources/Lithe/Application/AIAssistanceServiceBox.swift \
    macos/Sources/Lithe/Services/CommitMessageGenerationService.swift \
    macos/Sources/Lithe/Models/CommitMessageModels.swift; do
    if [[ -e "$legacy_ai_file" ]]; then
        print -u2 "AI Assistance implementation leaked outside LitheAIAssistanceModule: $legacy_ai_file"
        exit 1
    fi
done

for ai_type in AIAssistanceCapability CommitMessageGenerationService; do
    rg -q "(class|struct|protocol|enum) ${ai_type}" macos/Sources/LitheAIAssistanceModule || {
        print -u2 "AI Assistance module is missing real implementation: ${ai_type}"
        exit 1
    }
done

for ai_contract in AIHTTPTransport AIProviderCredentialResolver AIProviderProfile CommitMessageAISettings; do
    rg -q "(class|struct|protocol|enum) ${ai_contract}" macos/Sources/LitheCoreContracts || {
        print -u2 "AI Assistance shared contract is missing from LitheCoreContracts: ${ai_contract}"
        exit 1
    }
done

if rg -n '^import LitheAIAssistanceModule$' macos/Sources/Lithe/Application/Composition/AppServices.swift; then
    print -u2 "AppServices must consume shared AI contracts rather than the concrete AI module"
    exit 1
fi

if rg -n 'FeatureModuleHandle|AIAssistanceServiceBox' macos/Sources/LitheAIAssistanceModule; then
    print -u2 "AI Assistance must own its service graph rather than hosting an executable-target handle"
    exit 1
fi

for legacy_search_file in \
    macos/Sources/Lithe/Application/SearchFeatureModel.swift \
    macos/Sources/Lithe/Models/SearchModels.swift \
    macos/Sources/Lithe/Models/ProjectReplacementModels.swift; do
    if [[ -e "$legacy_search_file" ]]; then
        print -u2 "Search implementation leaked outside LitheSearchModule: $legacy_search_file"
        exit 1
    fi
done

for search_type in SearchFeatureModel SearchOperations FileSearchResult ProjectReplacementFile; do
    rg -q "(class|struct|protocol|enum) ${search_type}" macos/Sources/LitheSearchModule || {
        print -u2 "Search module is missing real implementation: ${search_type}"
        exit 1
    }
done

if rg -n 'FeatureModuleHandle' macos/Sources/LitheSearchModule; then
    print -u2 "Search must own its feature graph rather than hosting an executable-target handle"
    exit 1
fi

for legacy_history_file in \
    macos/Sources/Lithe/Application/ProjectHistoryFeatureModel.swift \
    macos/Sources/Lithe/Services/LocalHistoryService.swift \
    macos/Sources/Lithe/Models/LocalHistoryModels.swift; do
    if [[ -e "$legacy_history_file" ]]; then
        print -u2 "Local History implementation leaked outside LitheLocalHistoryModule: $legacy_history_file"
        exit 1
    fi
done

for history_type in ProjectHistoryFeatureModel LocalHistoryService LocalHistoryOperations LocalHistoryEntry; do
    rg -q "(actor|class|struct|protocol|enum) ${history_type}" macos/Sources/LitheLocalHistoryModule || {
        print -u2 "Local History module is missing real implementation: ${history_type}"
        exit 1
    }
done

if rg -n 'FeatureModuleHandle|EditorDocument|RustCoreBridge' macos/Sources/LitheLocalHistoryModule; then
    print -u2 "Local History must own its graph without executable, editor, or Rust bridge types"
    exit 1
fi

for legacy_git_file in \
    macos/Sources/Lithe/Application/GitFeatureModel.swift \
    macos/Sources/Lithe/Services/GitService.swift \
    macos/Sources/Lithe/Services/ShelveService.swift \
    macos/Sources/Lithe/Services/GitGraphLayoutService.swift \
    macos/Sources/Lithe/Models/GitModels.swift \
    macos/Sources/Lithe/Models/GitGraphModels.swift; do
    if [[ -e "$legacy_git_file" ]]; then
        print -u2 "Git implementation leaked outside LitheGitModule: $legacy_git_file"
        exit 1
    fi
done

for git_type in GitFeatureModel GitService ShelveService GitOperations GitGraphLayoutService; do
    rg -q "(class|struct|protocol|enum) ${git_type}" macos/Sources/LitheGitModule || {
        print -u2 "Git module is missing real implementation: ${git_type}"
        exit 1
    }
done

if rg -n 'FeatureModuleHandle|RustCoreBridge|FileStorage' macos/Sources/LitheGitModule; then
    print -u2 "Git must own its graph through ports without executable-target handles or adapters"
    exit 1
fi

if rg -n 'Debug(Adapter|Launch|Breakpoint|Thread|StackFrame|Scope|Variable|ExecutionCommand)' macos/Sources/Lithe/Core/Ports/LanguageTooling.swift; then
    print -u2 "Debug/DAP contracts leaked back into LanguageTooling.swift"
    exit 1
fi

if rg -n 'LanguageTest(Item|Scope|Context|Plan|Provider)' macos/Sources/Lithe/Core/Ports/LanguageTooling.swift; then
    print -u2 "Execution/Test contracts leaked back into LanguageTooling.swift"
    exit 1
fi

if rg -n 'terminal\.sessions|git\.log|language\.problems|execution\.(maven|run|tests)|debug\.session' macos/Sources/Lithe/Views/Workbench/WorkbenchView.swift; then
    print -u2 "Workbench switches on concrete module contribution IDs"
    exit 1
fi

for legacy_database_file in \
    macos/Sources/Lithe/Application/DatabaseFeatureModel.swift \
    macos/Sources/Lithe/Application/DatabaseSQLSupport.swift \
    macos/Sources/Lithe/Application/DatabaseSchemaDiff.swift \
    macos/Sources/Lithe/Services/DatabaseConnectionStore.swift \
    macos/Sources/Lithe/Services/DatabaseDBXImportService.swift \
    macos/Sources/Lithe/Services/DatabaseSidecarService.swift \
    macos/Sources/Lithe/Core/Ports/DatabaseRecovery.swift; do
    if [[ -e "$legacy_database_file" ]]; then
        print -u2 "Database implementation leaked outside LitheDatabaseModule: $legacy_database_file"
        exit 1
    fi
done

for database_type in DatabaseFeatureModel DatabaseSidecarService DatabaseConnectionStore DatabaseProcessRunning DatabaseRecoveryStoring; do
    rg -q "(class|struct|protocol|enum) ${database_type}" macos/Sources/LitheDatabaseModule || {
        print -u2 "Database module is missing real implementation: ${database_type}"
        exit 1
    }
done

if rg -n 'FeatureModuleHandle|ProcessRunner|KeyValueStore|SecureStore|FileStorage' macos/Sources/LitheDatabaseModule | rg -v 'Database(ProcessRunner|PreferenceStore|SecureStore|FileStorage)'; then
    print -u2 "Database must own its graph through database-scoped ports"
    exit 1
fi

for language_type in LanguageIntelligenceModule LanguageIntelligenceCapability LanguageIntelligenceServiceGraph; do
    rg -q "(class|struct|protocol|enum) ${language_type}" macos/Sources/LitheLanguageIntelligenceModule || {
        print -u2 "Language Intelligence module is missing its owned lifecycle boundary: ${language_type}"
        exit 1
    }
done

if rg -n '(FeatureModuleHandle\(|: HostedFeatureModule)' macos/Sources/LitheLanguageIntelligenceModule; then
    print -u2 "Language Intelligence must not host an arbitrary executable-target feature handle"
    exit 1
fi

if [[ ! -f macos/Tests/LitheLanguageIntelligenceModuleTests/LanguageIntelligenceModuleTests.swift ]]; then
    print -u2 "Language Intelligence module is missing independent lifecycle tests"
    exit 1
fi

for debug_type in DebugModule DebugModuleCapability DebugServiceGraph; do
    rg -q "(class|struct|protocol|enum) ${debug_type}" macos/Sources/LitheDebugModule || {
        print -u2 "Debug module is missing its owned lifecycle boundary: ${debug_type}"
        exit 1
    }
done

if rg -n '(FeatureModuleHandle\(|: HostedFeatureModule)' macos/Sources/LitheDebugModule; then
    print -u2 "Debug must not host an arbitrary executable-target feature handle"
    exit 1
fi

if [[ ! -f macos/Tests/LitheDebugModuleTests/DebugModuleTests.swift ]]; then
    print -u2 "Debug module is missing independent lifecycle tests"
    exit 1
fi

for execution_type in ExecutionModule ExecutionModuleCapability ExecutionServiceGraph; do
    rg -q "(class|struct|protocol|enum) ${execution_type}" macos/Sources/LitheExecutionModule || {
        print -u2 "Execution module is missing its owned lifecycle boundary: ${execution_type}"
        exit 1
    }
done

if rg -n '(FeatureModuleHandle\(|: HostedFeatureModule)' macos/Sources/LitheExecutionModule; then
    print -u2 "Execution must not host an arbitrary executable-target feature handle"
    exit 1
fi

if [[ ! -f macos/Tests/LitheExecutionModuleTests/ExecutionModuleTests.swift ]]; then
    print -u2 "Execution module is missing independent lifecycle tests"
    exit 1
fi

for workspace_type in WorkspaceFoundationModule WorkspaceFoundationCapability WorkspaceResourceGraph; do
    rg -q "(class|struct|protocol|enum) ${workspace_type}" macos/Sources/LitheWorkspaceModule || {
        print -u2 "Workspace module is missing its owned lifecycle boundary: ${workspace_type}"
        exit 1
    }
done

if rg -n '(FeatureModuleHandle\(|: HostedFeatureModule)' macos/Sources/LitheWorkspaceModule; then
    print -u2 "Workspace must not host an arbitrary executable-target feature handle"
    exit 1
fi

if [[ ! -f macos/Tests/LitheWorkspaceModuleTests/WorkspaceModuleTests.swift ]]; then
    print -u2 "Workspace module is missing independent lifecycle tests"
    exit 1
fi

if rg -n 'SearchFeatureModel\(' macos/Sources/Lithe/Models/AppModel/AppModel.swift; then
    print -u2 "Search must be constructed only by its module factory"
    exit 1
fi

if rg -n 'ProjectHistoryFeatureModel\(' macos/Sources/Lithe/Models/AppModel/AppModel.swift; then
    print -u2 "Local History must be constructed only by its module factory"
    exit 1
fi

if rg -n 'let (gitService|mavenService|runService|javaDebugService|languageTestService):|let (gitFeature|mavenFeature|runFeature|debugFeature|genericDebugFeature):' macos/Sources/Lithe/Application/Composition/AppServices.swift macos/Sources/Lithe/Models/AppModel/AppModel.swift; then
    print -u2 "Concrete feature module ownership leaked into AppServices or AppModel"
    exit 1
fi

for target in "${module_targets[@]}"; do
    if rg -n '^import (SwiftUI|AppKit|Lithe)$' "macos/Sources/${target}"; then
        print -u2 "Feature target ${target} imports UI or executable implementation"
        exit 1
    fi
done

if find macos/Sources -maxdepth 1 -type d -name 'Lithe*Module' | while read -r target; do
    [[ -n "$(find "$target" -type f -name '*.swift' -print -quit)" ]] || {
        print -u2 "Empty feature target is not a valid module boundary: $target"
        exit 1
    }
done; then
    :
else
    exit 1
fi

print "Module boundary verification passed: IDs, implementations, registrations, and lazy ownership checks are intact"
