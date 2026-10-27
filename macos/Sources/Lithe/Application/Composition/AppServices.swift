import Combine
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import LitheDebugModule
import LitheLanguageIntelligenceModule

/// Platform-neutral service graph consumed by application orchestration.
/// Platform composition roots construct this graph with their own adapters.
@MainActor
final class AppServices {
    var ideCapabilityRegistry: IdeCapabilityRegistry?
    var ideHostTransport: (any IdeHostTransport)?
    /// Codex and Claude Code MCP configuration files. `nil` before platform
    /// composition, which leaves the settings page read-only.
    var mcpConfigurationStore: (any McpConfigurationStore)?
    var mcpRegistry: (any McpRegistryProviding)?
    var mcpTools: (any McpToolsManaging)?
    /// Confirms closing terminals with running programs; `nil` closes directly.
    var processExitCoordinator: ProcessExitCoordinator?
    /// Creates projects for the New Project window; `nil` falls back to
    /// choosing an existing folder.
    var projectGeneration: ProjectGenerationService?
    /// Saved SSH connections and the connection test for the Remote
    /// Development window; `nil` hides the window's entry points.
    var remoteConnections: RemoteConnectionServices?
    /// Installed plugins with their enabled state, for the New Project
    /// catalog and the plugins that provide a generator's requirements.
    var projectGeneratorSources: (@MainActor () -> [ProjectGeneratorPluginSource])?
    /// Gives build providers that share a language server the language
    /// sessions; `nil` when the platform starts no build providers.
    var connectBuildProviderLanguageSessions: ((@escaping @MainActor () -> LanguageToolingSessionManager?) -> Void)?
    /// Plugin VCS providers; `nil` when no installed plugin declares one.
    var vcsProviders: VcsProvidersFeatureModel?
    /// Fires after plugins that take effect without a restart were installed,
    /// updated, removed, enabled or disabled; `nil` when the platform has none.
    var pluginRegistrationChanges: AnyPublisher<Void, Never>?
    let moduleRuntime: ModuleRuntime
    let pluginManager: any PluginManaging
    let pluginMarketplace: any PluginMarketplaceServicing
    let pluginCatalog: ValidatedPluginCatalog
    let pluginUIIconResources: [String: PluginUIIconResources]
    /// Plugin pages shown in host tool windows (`ui` 2).
    let pluginWebPages: PluginWebPages
    let validatePluginNativeUI: ((PluginNativeUI, ToolingJSONValue) throws -> [PluginNativeUI.Node])?
    /// Unified language-pack composition. The derived catalog and focused
    /// registries remain exposed below for source compatibility with existing
    /// feature models while new composition should use this value.
    let languageProviderCatalogSource: any LanguageProviderCatalogSource
    /// Initial catalog load outcome, including whether startup fell back to a
    /// compatibility catalog or rejected a workspace override.
    let languageProviderCatalogSnapshot: LanguageProviderCatalogSnapshot
    /// Metadata-only provider catalog; providers are activated on demand.
    let languageProviderCatalog: LanguageProviderCatalog
    let workspaceLanguageServerPreferences: any WorkspaceLanguageServerPreferencesStoring
    let debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver
    let debugPortAvailabilityChecker: any DebugPortAvailabilityChecking
    let javaTestDebugLaunchService: JavaTestDebugLaunchService
    let debugPerformanceSampler: (any DebugPerformanceSampling)?
    let testJVMPerformance: (any TestJVMPerformanceProviding)?
    let debugBreakpointPersistence: (any DebugBreakpointPersisting)?
    let workspaceOperations: any WorkspaceOperations
    let documentLifecycleDecider: any DocumentLifecycleDeciding
    /// Deterministic line-level editing transforms shared with Windows; the
    /// editor view applies the results through its native text engine.
    let lineEditing: any EditorLineEditing
    let javaMavenOperations: any JavaMavenOperations
    let markdownRenderer: any MarkdownRendering
    let markdownImageImporter: any MarkdownImageImporting
    let store: any KeyValueStore
    let fileStorage: any FileStorage
    let fileOperations: any WorkspaceFileOperations
    let agentEditRestorer: any AgentEditRestoring
    /// Empty by default; binary support exists only after an explicit registration.
    let binaryFileViewerRegistry: BinaryFileViewerRegistry
    let projectRuntimeService: ProjectRuntimeService
    let gitWatchContextProvider: any GitWatchContextProviding
    let githubService: GitHubService
    let secureStore: any SecureStore
    let diagnosticsExportService: DiagnosticsExportService
    let credentialResolver: any AIProviderCredentialResolver
    /// Detects Node.js and installs ACP adapters for the Agents settings page.
    let agentManagement: any AgentManagementService
    let agentInstructions: any AgentInstructionsService
    let agentHooks: any AgentHooksService
    /// Runs the official CLI login for an extra subscription account.
    let agentAccountSignIn: any AgentAccountSigningIn
    let agentProviderConfigurationParser: any AgentProviderConfigurationParsing
    let aiConfigurationSources: [any AIConfigurationSource]
    let recentProjectsStore: RecentProjectsStore
    let recentProjectBranchReader: any RecentProjectBranchReading
    let workspaceSessionStore: WorkspaceSessionStore
    let directoryMarkStore: any WorkspaceDirectoryMarkStoring
    let workbenchLayoutStore: WorkbenchLayoutStore
    let workbenchBackgroundPlatform: any WorkbenchBackgroundPlatformProviding
    let directoryWatcherFactory: any DirectoryWatcherFactory
    let platformUI: any PlatformUI
    let shortcutDetectorFactory: any ShortcutDetectorFactory

    init(
        moduleRuntime: ModuleRuntime,
        pluginManager: any PluginManaging,
        pluginMarketplace: any PluginMarketplaceServicing,
        pluginCatalog: ValidatedPluginCatalog,
        pluginUIIconResources: [String: PluginUIIconResources] = [:],
        pluginWebPages: PluginWebPages? = nil,
        validatePluginNativeUI: ((PluginNativeUI, ToolingJSONValue) throws -> [PluginNativeUI.Node])? = nil,
        languageProviderCatalogSource: any LanguageProviderCatalogSource,
        workspaceLanguageServerPreferences: any WorkspaceLanguageServerPreferencesStoring,
        languageProviderCatalogSnapshot: LanguageProviderCatalogSnapshot? = nil,
        debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver? = nil,
        debugPortAvailabilityChecker: (any DebugPortAvailabilityChecking)? = nil,
        javaTestResultServerFactory: @escaping @MainActor () -> any JavaTestResultServing,
        debugBreakpointPersistence: (any DebugBreakpointPersisting)? = nil,
        workspaceOperations: any WorkspaceOperations,
        documentLifecycleDecider: any DocumentLifecycleDeciding,
        lineEditing: any EditorLineEditing,
        javaMavenOperations: any JavaMavenOperations,
        markdownRenderer: any MarkdownRendering,
        markdownImageImporter: any MarkdownImageImporting,
        store: any KeyValueStore,
        fileStorage: any FileStorage,
        fileOperations: any WorkspaceFileOperations,
        agentEditRestorer: any AgentEditRestoring = UnavailableAgentEditRestorer(),
        binaryFileViewerRegistry: BinaryFileViewerRegistry,
        projectRuntimeService: ProjectRuntimeService,
        gitWatchContextProvider: any GitWatchContextProviding,
        githubService: GitHubService,
        secureStore: any SecureStore,
        diagnosticsExportService: DiagnosticsExportService,
        credentialResolver: any AIProviderCredentialResolver,
        agentManagement: any AgentManagementService = UnavailableAgentManagementService(),
        agentInstructions: any AgentInstructionsService = UnavailableAgentInstructionsService(),
        agentHooks: any AgentHooksService = UnavailableAgentHooksService(),
        agentAccountSignIn: any AgentAccountSigningIn = UnavailableAgentAccountSignIn(),
        agentProviderConfigurationParser: any AgentProviderConfigurationParsing = UnavailableAgentProviderConfigurationParser(),
        aiConfigurationSources: [any AIConfigurationSource],
        recentProjectsStore: RecentProjectsStore,
        recentProjectBranchReader: any RecentProjectBranchReading = UnavailableRecentProjectBranchReader(),
        workspaceSessionStore: WorkspaceSessionStore,
        directoryMarkStore: any WorkspaceDirectoryMarkStoring,
        workbenchLayoutStore: WorkbenchLayoutStore,
        workbenchBackgroundPlatform: any WorkbenchBackgroundPlatformProviding,
        directoryWatcherFactory: any DirectoryWatcherFactory,
        platformUI: any PlatformUI,
        shortcutDetectorFactory: any ShortcutDetectorFactory,
        debugPerformanceSampler: (any DebugPerformanceSampling)? = nil,
        testJVMPerformance: (any TestJVMPerformanceProviding)? = nil
    ) {
        self.debugPerformanceSampler = debugPerformanceSampler
        self.testJVMPerformance = testJVMPerformance
        self.moduleRuntime = moduleRuntime
        self.pluginManager = pluginManager
        self.pluginMarketplace = pluginMarketplace
        self.pluginCatalog = pluginCatalog
        self.pluginUIIconResources = pluginUIIconResources
        self.pluginWebPages = pluginWebPages ?? PluginWebPages()
        self.validatePluginNativeUI = validatePluginNativeUI
        self.languageProviderCatalogSource = languageProviderCatalogSource
        self.workspaceLanguageServerPreferences = workspaceLanguageServerPreferences
        let resolvedCatalogSnapshot = languageProviderCatalogSnapshot
            ?? languageProviderCatalogSource.load(workspaceURL: nil)
        self.languageProviderCatalogSnapshot = resolvedCatalogSnapshot
        let resolvedCatalog = resolvedCatalogSnapshot.catalog
        self.languageProviderCatalog = resolvedCatalog
        self.debugLaunchConfigurationResolver = debugLaunchConfigurationResolver
            ?? DebugLaunchConfigurationResolver()
        self.debugPortAvailabilityChecker = debugPortAvailabilityChecker
            ?? AlwaysAvailableDebugPortChecker()
        self.javaTestDebugLaunchService = JavaTestDebugLaunchService(
            configurationResolver: self.debugLaunchConfigurationResolver,
            resultServerFactory: javaTestResultServerFactory
        )
        self.debugBreakpointPersistence = debugBreakpointPersistence
        self.workspaceOperations = workspaceOperations
        self.documentLifecycleDecider = documentLifecycleDecider
        self.lineEditing = lineEditing
        self.javaMavenOperations = javaMavenOperations
        self.markdownRenderer = markdownRenderer
        self.markdownImageImporter = markdownImageImporter
        self.store = store
        self.fileStorage = fileStorage
        self.fileOperations = fileOperations
        self.agentEditRestorer = agentEditRestorer
        self.binaryFileViewerRegistry = binaryFileViewerRegistry
        self.projectRuntimeService = projectRuntimeService
        self.gitWatchContextProvider = gitWatchContextProvider
        self.githubService = githubService
        self.secureStore = secureStore
        self.diagnosticsExportService = diagnosticsExportService
        self.credentialResolver = credentialResolver
        self.agentManagement = agentManagement
        self.agentInstructions = agentInstructions
        self.agentHooks = agentHooks
        self.agentAccountSignIn = agentAccountSignIn
        self.agentProviderConfigurationParser = agentProviderConfigurationParser
        self.aiConfigurationSources = aiConfigurationSources
        self.recentProjectsStore = recentProjectsStore
        self.recentProjectBranchReader = recentProjectBranchReader
        self.workspaceSessionStore = workspaceSessionStore
        self.directoryMarkStore = directoryMarkStore
        self.workbenchLayoutStore = workbenchLayoutStore
        self.workbenchBackgroundPlatform = workbenchBackgroundPlatform
        self.directoryWatcherFactory = directoryWatcherFactory
        self.platformUI = platformUI
        self.shortcutDetectorFactory = shortcutDetectorFactory
    }
}
