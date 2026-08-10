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
    /// Unified language-pack composition. The derived catalog and focused
    /// registries remain exposed below for source compatibility with existing
    /// feature models while new composition should use this value.
    let languagePacks: LanguagePackRegistry
    /// Metadata-only provider catalog; providers are activated on demand.
    let languageProviderCatalog: LanguageProviderCatalog
    let runToolchainRegistry: RunToolchainRegistry
    let languageToolingSessions: LanguageToolingSessionManager
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
    let projectRuntimeService: ProjectRuntimeService
    let javaLanguageService: JavaLanguageService
    let javaImplementationMarkerService: JavaImplementationMarkerService
    let mavenService: MavenService
    let runService: RunService
    let javaDebugService: JavaDebugService
    let gitService: GitService
    let shelveService: ShelveService
    let commitMessageGenerator: CommitMessageGenerationService
    let secureStore: any SecureStore
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
        languageProviderCatalog: LanguageProviderCatalog = .standard,
        languagePacks: LanguagePackRegistry? = nil,
        runToolchainRegistry: RunToolchainRegistry? = nil,
        languageToolingSessions: LanguageToolingSessionManager? = nil,
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
        projectRuntimeService: ProjectRuntimeService,
        javaLanguageService: JavaLanguageService,
        javaImplementationMarkerService: JavaImplementationMarkerService,
        mavenService: MavenService,
        runService: RunService,
        javaDebugService: JavaDebugService,
        gitService: GitService,
        shelveService: ShelveService,
        commitMessageGenerator: CommitMessageGenerationService,
        secureStore: any SecureStore,
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
        let resolvedLanguagePacks = languagePacks ?? LanguagePackRegistry.standard(
            catalog: languageProviderCatalog,
            runtimes: [
                JavaLanguageProviderRuntime(
                    service: javaLanguageService,
                    catalog: languageProviderCatalog
                )
            ]
        )
        self.languagePacks = resolvedLanguagePacks
        self.languageProviderCatalog = resolvedLanguagePacks.catalog
        self.runToolchainRegistry = runToolchainRegistry ?? resolvedLanguagePacks.toolchainRegistry
        self.languageToolingSessions = languageToolingSessions ?? LanguageToolingSessionManager(
            registry: resolvedLanguagePacks
        )
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
        self.projectRuntimeService = projectRuntimeService
        self.javaLanguageService = javaLanguageService
        self.javaImplementationMarkerService = javaImplementationMarkerService
        self.mavenService = mavenService
        self.runService = runService
        self.javaDebugService = javaDebugService
        self.gitService = gitService
        self.shelveService = shelveService
        self.commitMessageGenerator = commitMessageGenerator
        self.secureStore = secureStore
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
