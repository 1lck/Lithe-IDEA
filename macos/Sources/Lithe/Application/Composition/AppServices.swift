import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheDebugModule

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
    let debugPortAvailabilityChecker: any DebugPortAvailabilityChecking
    let javaTestDebugLaunchService: JavaTestDebugLaunchService
    let debugBreakpointPersistence: (any DebugBreakpointPersisting)?
    let workspaceOperations: any WorkspaceOperations
    let documentLifecycleDecider: any DocumentLifecycleDeciding
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
    let workbenchBackgroundPlatform: any WorkbenchBackgroundPlatformProviding
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
        debugPortAvailabilityChecker: (any DebugPortAvailabilityChecking)? = nil,
        javaTestResultServerFactory: @escaping @MainActor () -> any JavaTestResultServing,
        debugBreakpointPersistence: (any DebugBreakpointPersisting)? = nil,
        workspaceOperations: any WorkspaceOperations,
        documentLifecycleDecider: any DocumentLifecycleDeciding,
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
        workbenchBackgroundPlatform: any WorkbenchBackgroundPlatformProviding,
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
        self.debugPortAvailabilityChecker = debugPortAvailabilityChecker
            ?? AlwaysAvailableDebugPortChecker()
        self.javaTestDebugLaunchService = JavaTestDebugLaunchService(
            configurationResolver: self.debugLaunchConfigurationResolver,
            resultServerFactory: javaTestResultServerFactory
        )
        self.debugBreakpointPersistence = debugBreakpointPersistence
        self.workspaceOperations = workspaceOperations
        self.documentLifecycleDecider = documentLifecycleDecider
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
        self.workbenchBackgroundPlatform = workbenchBackgroundPlatform
        self.directoryWatcherFactory = directoryWatcherFactory
        self.platformUI = platformUI
        self.shortcutDetectorFactory = shortcutDetectorFactory
    }
}
