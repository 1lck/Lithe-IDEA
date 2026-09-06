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
    let workbench: WorkbenchFeatureModel
    let commitDraft: CommitDraftFeatureModel
    let searchSession: SearchSessionFeatureModel
    let workspaceSession: WorkspaceSessionCoordinator
    let workbenchBackground: WorkbenchBackgroundFeatureModel
    let runtime: RuntimeSettingsFeatureModel
    let languageTooling: LanguageToolingFeatureModel
    let workspace: WorkspaceFeatureModel
    let github: GitHubFeatureModel
    let discourseCommunity: DiscourseCommunityFeatureModel
    let editorTabOrder: EditorTabOrderFeatureModel
    let media: MediaDocumentFeatureModel
    let terminalPlacement: TerminalPlacementFeatureModel
    let document: DocumentFeatureModel
    let navigationHistory: NavigationHistoryFeatureModel
    let java: JavaFeatureModel
    let spring: SpringFeatureModel
    let editorSession: EditorSessionCoordinator
    let javaTestWorkflow: JavaTestWorkflowState
    let languageNavigation: LanguageNavigationCoordinator
    let languageEditing: LanguageEditingCoordinator
    let languageWorkspaceEdit: LanguageWorkspaceEditService
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
        workspaceSession = WorkspaceSessionCoordinator(
            recentProjectsStore: services.recentProjectsStore,
            platformUI: services.platformUI,
            workspaceFeature: workspace
        )
        workbenchBackground = WorkbenchBackgroundFeatureModel(
            settings: settings,
            platform: services.workbenchBackgroundPlatform
        )
        runtime = RuntimeSettingsFeatureModel(service: services.projectRuntimeService)
        languageTooling = LanguageToolingFeatureModel(
            catalogSource: services.languageProviderCatalogSource,
            catalogSnapshot: services.languageProviderCatalogSnapshot,
            sessionsProvider: { nil }
        )
        github = GitHubFeatureModel(service: services.githubService)
        discourseCommunity = DiscourseCommunityFeatureModel(
            service: services.discourseCommunityService
        )
        editorTabOrder = EditorTabOrderFeatureModel()
        media = MediaDocumentFeatureModel()
        terminalPlacement = TerminalPlacementFeatureModel()
        document = DocumentFeatureModel(
            operations: services.workspaceOperations,
            documentLifecycleDecider: services.documentLifecycleDecider,
            fileOperations: services.fileOperations,
            fileStorage: services.fileStorage,
            binaryFileViewerRegistry: services.binaryFileViewerRegistry
        )
        navigationHistory = NavigationHistoryFeatureModel()
        java = JavaFeatureModel(operations: services.javaMavenOperations)
        spring = SpringFeatureModel(operations: services.javaMavenOperations)
        javaTestWorkflow = JavaTestWorkflowState(notify: notify)
        languageNavigation = LanguageNavigationCoordinator(notify: notify)
        languageEditing = LanguageEditingCoordinator(notify: notify)
        languageWorkspaceEdit = LanguageWorkspaceEditService(notify: notify)
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
