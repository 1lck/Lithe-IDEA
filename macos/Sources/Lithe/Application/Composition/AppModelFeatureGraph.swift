import Foundation
import LitheCoreContracts
import LitheWorkspaceModule

/// Constructs the per-session feature models used by AppModel.
///
/// Owns feature construction and editor-session coordination. Module activation
/// and the remaining application callbacks are composed separately.
@MainActor
final class AppModelFeatureGraph {
    let keyboardShortcut: KeyboardShortcutFeatureModel
    let notification: WorkbenchNotificationFeatureModel
    /// Plugin messages show their own text verbatim, so they are not part of `notification`.
    let pluginMessages = PluginHostMessageFeatureModel()
    let workbench: WorkbenchFeatureModel
    let commitDraft: CommitDraftFeatureModel
    let searchSession: SearchSessionFeatureModel
    let workspaceSession: WorkspaceSessionCoordinator
    let workbenchBackground: WorkbenchBackgroundFeatureModel
    let runtime: RuntimeSettingsFeatureModel
    let toolchainSettings: ToolchainSettingsFeatureModel
    let languageTooling: LanguageToolingFeatureModel
    let workspace: WorkspaceFeatureModel
    let github: GitHubFeatureModel
    let diagnostics: DiagnosticsFeatureModel
    let editorTabOrder: EditorTabOrderFeatureModel
    let media: MediaDocumentFeatureModel
    let terminalPlacement: TerminalPlacementFeatureModel
    let document: DocumentFeatureModel
    let navigationHistory: NavigationHistoryFeatureModel
    let java: JavaFeatureModel
    let spring: SpringFeatureModel
    let mybatis: MybatisFeatureModel
    let editorSession: EditorSessionCoordinator
    let javaTestWorkflow: JavaTestWorkflowState
    let languageNavigation: LanguageNavigationCoordinator
    let languageEditing: LanguageEditingCoordinator
    let languageCapabilityPolicy: LanguageCapabilityPolicy
    let debugLaunchPreparation: DebugLaunchPreparationCoordinator
    let debugSessionCleanup: DebugSessionCleanupCoordinator
    let javaTestDebugWorkflow: JavaTestDebugWorkflowCoordinator

    init(settings: AppSettings, services: AppServices) {
        keyboardShortcut = KeyboardShortcutFeatureModel(settings: settings)
        let notification = WorkbenchNotificationFeatureModel()
        self.notification = notification
        // Coordinators report user-facing failures through the notification
        // feature directly; the application shell forwards the same call.
        let notify: @MainActor (String) -> Void = { message in
            notification.show(message)
        }
        workbench = WorkbenchFeatureModel(layoutStore: services.workbenchLayoutStore)
        commitDraft = CommitDraftFeatureModel()
        searchSession = SearchSessionFeatureModel()
        let workspace = WorkspaceFeatureModel(
            operations: services.workspaceOperations,
            fileOperations: services.fileOperations,
            gitWatchContextProvider: services.gitWatchContextProvider,
            directoryWatcherFactory: services.directoryWatcherFactory,
            workspaceSessionStore: services.workspaceSessionStore,
            directoryMarkStore: services.directoryMarkStore
        )
        self.workspace = workspace
        services.toolchainSettingsDirectories = { [weak workspace] in
            guard let root = workspace?.rootNode else { return [] }
            let prefix = root.url.standardizedFileURL.path + "/"
            var pending = root.children ?? []
            var paths: [String] = []
            while !pending.isEmpty && paths.count < 1_024 {
                let node = pending.removeLast()
                guard node.isDirectory else { continue }
                let path = node.url.standardizedFileURL.path
                if path.hasPrefix(prefix) { paths.append(String(path.dropFirst(prefix.count))) }
                pending.append(contentsOf: node.children ?? [])
            }
            return paths
        }
        workspaceSession = WorkspaceSessionCoordinator(
            recentProjectsStore: services.recentProjectsStore,
            platformUI: services.platformUI,
            recentProjectBranchReader: services.recentProjectBranchReader,
            workspaceFeature: workspace
        )
        workbenchBackground = WorkbenchBackgroundFeatureModel(
            settings: settings,
            platform: services.workbenchBackgroundPlatform
        )
        runtime = RuntimeSettingsFeatureModel(service: services.projectRuntimeService)
        toolchainSettings = ToolchainSettingsFeatureModel(
            loader: services.toolchainSettingsLoader, loginShell: services.loginShellEnvironmentInspector
        )
        languageTooling = LanguageToolingFeatureModel(
            catalogSource: services.languageProviderCatalogSource,
            catalogSnapshot: services.languageProviderCatalogSnapshot,
            preferences: services.workspaceLanguageServerPreferences,
            sessionsProvider: { nil }
        )
        github = GitHubFeatureModel(service: services.githubService)
        diagnostics = DiagnosticsFeatureModel(service: services.diagnosticsExportService)
        editorTabOrder = EditorTabOrderFeatureModel()
        media = MediaDocumentFeatureModel()
        terminalPlacement = TerminalPlacementFeatureModel()
        document = DocumentFeatureModel(
            operations: services.workspaceOperations,
            documentLifecycleDecider: services.documentLifecycleDecider,
            fileOperations: services.fileOperations,
            fileStorage: services.fileStorage,
            binaryFileViewerRegistry: services.binaryFileViewerRegistry,
            confirmHardLinkSave: { services.platformUI.confirmHardLinkSave(at: $0) }
        )
        navigationHistory = NavigationHistoryFeatureModel()
        java = JavaFeatureModel(operations: services.javaMavenOperations)
        spring = SpringFeatureModel(operations: services.javaMavenOperations)
        mybatis = MybatisFeatureModel(operations: services.javaMavenOperations)
        javaTestWorkflow = JavaTestWorkflowState(notify: notify)
        languageNavigation = LanguageNavigationCoordinator(notify: notify)
        languageEditing = LanguageEditingCoordinator(notify: notify)
        languageCapabilityPolicy = LanguageCapabilityPolicy()
        debugLaunchPreparation = DebugLaunchPreparationCoordinator(notify: notify)
        debugSessionCleanup = DebugSessionCleanupCoordinator()
        javaTestDebugWorkflow = JavaTestDebugWorkflowCoordinator(notify: notify)
        editorSession = EditorSessionCoordinator(
            document: document,
            media: media,
            terminalPlacement: terminalPlacement,
            tabOrder: editorTabOrder
        )
    }
}
