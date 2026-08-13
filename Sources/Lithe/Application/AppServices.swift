import Foundation

protocol DirectoryWatcherFactory {
    func make(
        configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) -> any DirectoryChangeSource
}

/// Platform-neutral service graph consumed by application orchestration.
/// Platform composition roots construct this graph with their own adapters.
@MainActor
final class AppServices {
    /// Unified language-pack composition. The derived catalog and focused
    /// registries remain exposed below for source compatibility with existing
    /// feature models while new composition should use this value.
    let languagePacks: LanguagePackRegistry
    let languageProviderCatalogSource: any LanguageProviderCatalogSource
    /// Initial catalog load outcome, including whether startup fell back to a
    /// compatibility catalog or rejected a workspace override.
    let languageProviderCatalogSnapshot: LanguageProviderCatalogSnapshot
    /// Metadata-only provider catalog; providers are activated on demand.
    let languageProviderCatalog: LanguageProviderCatalog
    let runToolchainRegistry: RunToolchainRegistry
    let languageToolingSessions: LanguageToolingSessionManager
    let languageServerTools: LanguageServerToolService
    let debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver
    let languageTestService: LanguageTestService
    let workspaceOperations: any WorkspaceOperations
    let localHistoryOperations: any LocalHistoryOperations
    let javaMavenOperations: any JavaMavenOperations
    let markdownRenderer: any MarkdownRendering
    let markdownImageImporter: any MarkdownImageImporting
    let store: any KeyValueStore
    let fileStorage: any FileStorage
    let fileOperations: any WorkspaceFileOperations
    /// Empty by default; binary support exists only after an explicit registration.
    let binaryFileViewerRegistry: BinaryFileViewerRegistry
    let projectRuntimeService: ProjectRuntimeService
    let mavenService: MavenService
    let runService: RunService
    let javaDebugService: JavaDebugService
    let gitService: GitService
    let databaseOperations: any DatabaseOperations
    let databaseRecoveryStore: any DatabaseRecoveryStoring
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
    let shellDiscovery: () -> [String]
    let directoryWatcherFactory: any DirectoryWatcherFactory
    let platformUI: any PlatformUI
    let shortcutDetectorFactory: any ShortcutDetectorFactory

    init(
        languageProviderCatalogSource: any LanguageProviderCatalogSource,
        languageProviderCatalogSnapshot: LanguageProviderCatalogSnapshot? = nil,
        languagePacks: LanguagePackRegistry? = nil,
        runToolchainRegistry: RunToolchainRegistry? = nil,
        languageToolingSessions: LanguageToolingSessionManager? = nil,
        languageServerTools: LanguageServerToolService,
        debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver? = nil,
        languageTestService: LanguageTestService,
        workspaceOperations: any WorkspaceOperations,
        localHistoryOperations: any LocalHistoryOperations,
        javaMavenOperations: any JavaMavenOperations,
        markdownRenderer: any MarkdownRendering,
        markdownImageImporter: any MarkdownImageImporting,
        store: any KeyValueStore,
        fileStorage: any FileStorage,
        fileOperations: any WorkspaceFileOperations,
        binaryFileViewerRegistry: BinaryFileViewerRegistry,
        projectRuntimeService: ProjectRuntimeService,
        mavenService: MavenService,
        runService: RunService,
        javaDebugService: JavaDebugService,
        gitService: GitService,
        databaseOperations: any DatabaseOperations,
        databaseRecoveryStore: any DatabaseRecoveryStoring,
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
        shellDiscovery: @escaping () -> [String],
        directoryWatcherFactory: any DirectoryWatcherFactory,
        platformUI: any PlatformUI,
        shortcutDetectorFactory: any ShortcutDetectorFactory
    ) {
        self.languageProviderCatalogSource = languageProviderCatalogSource
        let resolvedCatalogSnapshot = languageProviderCatalogSnapshot
            ?? languageProviderCatalogSource.load(workspaceURL: nil)
        self.languageProviderCatalogSnapshot = resolvedCatalogSnapshot
        let resolvedCatalog = resolvedCatalogSnapshot.catalog
        let resolvedLanguagePacks = languagePacks ?? LanguagePackRegistry.standard(
            catalog: resolvedCatalog
        )
        self.languagePacks = resolvedLanguagePacks
        self.languageProviderCatalog = resolvedLanguagePacks.catalog
        self.runToolchainRegistry = runToolchainRegistry ?? resolvedLanguagePacks.toolchainRegistry
        self.languageToolingSessions = languageToolingSessions ?? LanguageToolingSessionManager(
            registry: resolvedLanguagePacks
        )
        self.languageServerTools = languageServerTools
        self.debugLaunchConfigurationResolver = debugLaunchConfigurationResolver
            ?? DebugLaunchConfigurationResolver(fileStorage: fileStorage)
        self.languageTestService = languageTestService
        self.workspaceOperations = workspaceOperations
        self.localHistoryOperations = localHistoryOperations
        self.javaMavenOperations = javaMavenOperations
        self.markdownRenderer = markdownRenderer
        self.markdownImageImporter = markdownImageImporter
        self.store = store
        self.fileStorage = fileStorage
        self.fileOperations = fileOperations
        self.binaryFileViewerRegistry = binaryFileViewerRegistry
        self.projectRuntimeService = projectRuntimeService
        self.mavenService = mavenService
        self.runService = runService
        self.javaDebugService = javaDebugService
        self.gitService = gitService
        self.databaseOperations = databaseOperations
        self.databaseRecoveryStore = databaseRecoveryStore
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
        self.shellDiscovery = shellDiscovery
        self.directoryWatcherFactory = directoryWatcherFactory
        self.platformUI = platformUI
        self.shortcutDetectorFactory = shortcutDetectorFactory
    }
}
