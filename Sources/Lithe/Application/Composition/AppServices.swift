import Foundation
import LitheApplicationKernel
import LitheCoreContracts

/// Platform-neutral service graph consumed by application orchestration.
/// Platform composition roots construct this graph with their own adapters.
@MainActor
final class AppServices {
    let moduleRuntime: ModuleRuntime
    let pluginManager: any PluginManaging
    let pluginCatalog: ValidatedPluginCatalog
    /// Unified language-pack composition. The derived catalog and focused
    /// registries remain exposed below for source compatibility with existing
    /// feature models while new composition should use this value.
    let languageProviderCatalogSource: any LanguageProviderCatalogSource
    /// Initial catalog load outcome, including whether startup fell back to a
    /// compatibility catalog or rejected a workspace override.
    let languageProviderCatalogSnapshot: LanguageProviderCatalogSnapshot
    /// Metadata-only provider catalog; providers are activated on demand.
    let languageProviderCatalog: LanguageProviderCatalog
    let debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver
    let workspaceOperations: any WorkspaceOperations
    let javaMavenOperations: any JavaMavenOperations
    let markdownRenderer: any MarkdownRendering
    let markdownImageImporter: any MarkdownImageImporting
    let store: any KeyValueStore
    let fileStorage: any FileStorage
    let fileOperations: any WorkspaceFileOperations
    /// Empty by default; binary support exists only after an explicit registration.
    let binaryFileViewerRegistry: BinaryFileViewerRegistry
    let projectRuntimeService: ProjectRuntimeService
    let gitWatchContextProvider: any GitWatchContextProviding
    let githubService: GitHubService
    let secureStore: any SecureStore
    let databaseSecureStore: any SecureStore
    let discourseCommunityService: DiscourseCommunityService
    let credentialResolver: any AIProviderCredentialResolver
    let aiConfigurationSources: [any AIConfigurationSource]
    let recentProjectsStore: RecentProjectsStore
    let workspaceSessionStore: WorkspaceSessionStore
    let workbenchLayoutStore: WorkbenchLayoutStore
    let directoryWatcherFactory: any DirectoryWatcherFactory
    let platformUI: any PlatformUI
    let shortcutDetectorFactory: any ShortcutDetectorFactory

    init(
        moduleRuntime: ModuleRuntime,
        pluginManager: any PluginManaging,
        pluginCatalog: ValidatedPluginCatalog,
        languageProviderCatalogSource: any LanguageProviderCatalogSource,
        languageProviderCatalogSnapshot: LanguageProviderCatalogSnapshot? = nil,
        debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver? = nil,
        workspaceOperations: any WorkspaceOperations,
        javaMavenOperations: any JavaMavenOperations,
        markdownRenderer: any MarkdownRendering,
        markdownImageImporter: any MarkdownImageImporting,
        store: any KeyValueStore,
        fileStorage: any FileStorage,
        fileOperations: any WorkspaceFileOperations,
        binaryFileViewerRegistry: BinaryFileViewerRegistry,
        projectRuntimeService: ProjectRuntimeService,
        gitWatchContextProvider: any GitWatchContextProviding,
        githubService: GitHubService,
        secureStore: any SecureStore,
        databaseSecureStore: any SecureStore,
        discourseCommunityService: DiscourseCommunityService,
        credentialResolver: any AIProviderCredentialResolver,
        aiConfigurationSources: [any AIConfigurationSource],
        recentProjectsStore: RecentProjectsStore,
        workspaceSessionStore: WorkspaceSessionStore,
        workbenchLayoutStore: WorkbenchLayoutStore,
        directoryWatcherFactory: any DirectoryWatcherFactory,
        platformUI: any PlatformUI,
        shortcutDetectorFactory: any ShortcutDetectorFactory
    ) {
        self.moduleRuntime = moduleRuntime
        self.pluginManager = pluginManager
        self.pluginCatalog = pluginCatalog
        self.languageProviderCatalogSource = languageProviderCatalogSource
        let resolvedCatalogSnapshot = languageProviderCatalogSnapshot
            ?? languageProviderCatalogSource.load(workspaceURL: nil)
        self.languageProviderCatalogSnapshot = resolvedCatalogSnapshot
        let resolvedCatalog = resolvedCatalogSnapshot.catalog
        self.languageProviderCatalog = resolvedCatalog
        self.debugLaunchConfigurationResolver = debugLaunchConfigurationResolver
            ?? DebugLaunchConfigurationResolver(fileStorage: fileStorage)
        self.workspaceOperations = workspaceOperations
        self.javaMavenOperations = javaMavenOperations
        self.markdownRenderer = markdownRenderer
        self.markdownImageImporter = markdownImageImporter
        self.store = store
        self.fileStorage = fileStorage
        self.fileOperations = fileOperations
        self.binaryFileViewerRegistry = binaryFileViewerRegistry
        self.projectRuntimeService = projectRuntimeService
        self.gitWatchContextProvider = gitWatchContextProvider
        self.githubService = githubService
        self.secureStore = secureStore
        self.databaseSecureStore = databaseSecureStore
        self.discourseCommunityService = discourseCommunityService
        self.credentialResolver = credentialResolver
        self.aiConfigurationSources = aiConfigurationSources
        self.recentProjectsStore = recentProjectsStore
        self.workspaceSessionStore = workspaceSessionStore
        self.workbenchLayoutStore = workbenchLayoutStore
        self.directoryWatcherFactory = directoryWatcherFactory
        self.platformUI = platformUI
        self.shortcutDetectorFactory = shortcutDetectorFactory
    }
}
