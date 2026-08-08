import Foundation

protocol DirectoryWatcherFactory {
    func make(
        root: URL,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable ([String]) -> Void
    ) -> any DirectoryChangeSource
}

/// Platform-neutral service graph consumed by application orchestration.
/// Platform composition roots construct this graph with their own adapters.
@MainActor
final class AppServices {
    let workspaceOperations: any WorkspaceOperations
    let localHistoryOperations: any LocalHistoryOperations
    let javaMavenOperations: any JavaMavenOperations
    let markdownRenderer: any MarkdownRendering
    let markdownImageImporter: any MarkdownImageImporting
    let store: any KeyValueStore
    let fileStorage: any FileStorage
    let fileOperations: any WorkspaceFileOperations
    let projectRuntimeService: ProjectRuntimeService
    let javaLanguageService: JavaLanguageService
    let javaImplementationMarkerService: JavaImplementationMarkerService
    let mavenService: MavenService
    let javaRunService: JavaRunService
    let javaDebugService: JavaDebugService
    let gitService: GitService
    let databaseOperations: any DatabaseOperations
    let shelveService: ShelveService
    let commitMessageGenerator: CommitMessageGenerationService
    let secureStore: any SecureStore
    let databaseSecureStore: any SecureStore
    let credentialResolver: any AIProviderCredentialResolver
    let aiConfigurationSources: [any AIConfigurationSource]
    let recentProjectsStore: RecentProjectsStore
    let workspaceSessionStore: WorkspaceSessionStore
    let workbenchLayoutStore: WorkbenchLayoutStore
    let terminalFactory: () -> any TerminalTransport
    let directoryWatcherFactory: any DirectoryWatcherFactory
    let platformUI: any PlatformUI
    let shortcutDetectorFactory: any ShortcutDetectorFactory

    init(
        workspaceOperations: any WorkspaceOperations,
        localHistoryOperations: any LocalHistoryOperations,
        javaMavenOperations: any JavaMavenOperations,
        markdownRenderer: any MarkdownRendering,
        markdownImageImporter: any MarkdownImageImporting,
        store: any KeyValueStore,
        fileStorage: any FileStorage,
        fileOperations: any WorkspaceFileOperations,
        projectRuntimeService: ProjectRuntimeService,
        javaLanguageService: JavaLanguageService,
        javaImplementationMarkerService: JavaImplementationMarkerService,
        mavenService: MavenService,
        javaRunService: JavaRunService,
        javaDebugService: JavaDebugService,
        gitService: GitService,
        databaseOperations: any DatabaseOperations,
        shelveService: ShelveService,
        commitMessageGenerator: CommitMessageGenerationService,
        secureStore: any SecureStore,
        databaseSecureStore: any SecureStore,
        credentialResolver: any AIProviderCredentialResolver,
        aiConfigurationSources: [any AIConfigurationSource],
        recentProjectsStore: RecentProjectsStore,
        workspaceSessionStore: WorkspaceSessionStore,
        workbenchLayoutStore: WorkbenchLayoutStore,
        terminalFactory: @escaping () -> any TerminalTransport,
        directoryWatcherFactory: any DirectoryWatcherFactory,
        platformUI: any PlatformUI,
        shortcutDetectorFactory: any ShortcutDetectorFactory
    ) {
        self.workspaceOperations = workspaceOperations
        self.localHistoryOperations = localHistoryOperations
        self.javaMavenOperations = javaMavenOperations
        self.markdownRenderer = markdownRenderer
        self.markdownImageImporter = markdownImageImporter
        self.store = store
        self.fileStorage = fileStorage
        self.fileOperations = fileOperations
        self.projectRuntimeService = projectRuntimeService
        self.javaLanguageService = javaLanguageService
        self.javaImplementationMarkerService = javaImplementationMarkerService
        self.mavenService = mavenService
        self.javaRunService = javaRunService
        self.javaDebugService = javaDebugService
        self.gitService = gitService
        self.databaseOperations = databaseOperations
        self.shelveService = shelveService
        self.commitMessageGenerator = commitMessageGenerator
        self.secureStore = secureStore
        self.databaseSecureStore = databaseSecureStore
        self.credentialResolver = credentialResolver
        self.aiConfigurationSources = aiConfigurationSources
        self.recentProjectsStore = recentProjectsStore
        self.workspaceSessionStore = workspaceSessionStore
        self.workbenchLayoutStore = workbenchLayoutStore
        self.terminalFactory = terminalFactory
        self.directoryWatcherFactory = directoryWatcherFactory
        self.platformUI = platformUI
        self.shortcutDetectorFactory = shortcutDetectorFactory
    }
}
