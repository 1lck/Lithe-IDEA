import Foundation
import LitheAIAssistanceModule
import LitheAgentConversationModule
import LitheApplicationKernel
import LitheCoreContracts
import LitheDatabaseModule
import LitheDebugModule
import LitheExecutionModule
import LitheGitModule
import LitheLocalHistoryModule
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import LitheSearchModule
import LitheTerminalModule
import LitheWorkspaceModule

private struct MacDirectoryWatcherFactory: DirectoryWatcherFactory {
    func make(
        configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) -> any DirectoryChangeSource {
        MacDirectoryWatcher(
            configuration: configuration,
            visibilityRules: visibilityRules,
            onChange: onChange
        )
    }
}

/// macOS composition root for the application services.
///
/// UI models receive this container instead of constructing platform adapters
/// themselves. Windows will provide an equivalent composition root without
/// changing the application-facing orchestration.
// Note: Module runtime boundaries and lifecycle rules live in
// .agents/notes/implemented/architecture/2026-09-13-module-runtime-boundaries-and-lifecycle.md
@MainActor
final class MacServiceContainer {
    let services: AppServices
    let runConfigurationStore: MacRunConfigurationStore
    let moduleLifecycleCoordinator: ModuleLifecycleCoordinator

    static func makeLogDirectoryProvider() -> any LogDirectoryProviding {
        MacLogDirectoryProvider()
    }

    static func makeApplicationLogWriter(onDirectoryFallback: @escaping @Sendable () -> Void = {}) -> MacApplicationLogWriter {
        MacApplicationLogWriter(onDirectoryFallback: onDirectoryFallback)
    }

    static func makeDiagnosticsExportService(
        fileStorage: any FileStorage,
        processRunner: any ProcessRunner,
        core: RustCoreBridge,
        applicationLogging: (any ApplicationLogging)? = nil
    ) -> DiagnosticsExportService {
        DiagnosticsExportService(
            logDirectoryProviding: makeLogDirectoryProvider(),
            fileStorage: fileStorage,
            systemDiagnostics: MacSystemDiagnosticsProvider(),
            archiver: MacDittoArchiver(processRunner: processRunner),
            core: core,
            applicationLogging: applicationLogging
        )
    }

    init(
        store: any KeyValueStore,
        settings: AppSettings,
        processRegistry: ManagedProcessRegistry = ManagedProcessRegistry(),
        moduleLaunchMode: ModuleLaunchMode = .normal,
        moduleStore providedModuleStore: MacModuleConfigurationStore? = nil,
        workspaceOperations providedWorkspaceOperations: (any WorkspaceOperations)? = nil,
        javaMavenOperations providedJavaMavenOperations: (any JavaMavenOperations)? = nil,
        runConfigurationOperations providedRunConfigurationOperations: (any RunConfigurationOperations)? = nil,
        gitWatchContextProvider providedGitWatchContextProvider: (any GitWatchContextProviding)? = nil,
        runExecutableResolver providedRunExecutableResolver: (any RunExecutableResolving)? = nil,
        platformUI providedPlatformUI: (any PlatformUI)? = nil,
        aiConfigurationSources providedAIConfigurationSources: [any AIConfigurationSource]? = nil,
        gitPerformanceLogger: (any GitPerformanceLogger)? = nil,
        pluginWebPageLifecycle providedPluginWebPageLifecycle: PluginWebPageLifecycle? = nil,
        applicationLogging: (any ApplicationLogging)? = nil
    ) {
        let pluginWebPageLifecycle = providedPluginWebPageLifecycle ?? .shared
        let gitExecutionJournal = GitExecutionJournal()
        gitExecutionJournal.onLifecycleEvent = { event in
            applicationLogging?.record(level: event.error != nil || (event.exitCode ?? 0) != 0 ? "error" : "info",
                scope: "git.execution", message: event.type,
                fields: ["operation_id": event.operationId, "duration_ms": event.durationMilliseconds.map(String.init) ?? "",
                    "exit_code": event.exitCode.map(String.init) ?? "", "error_code": event.error?.code ?? ""])
        }
        let rustCore = RustCoreBridge(gitPreferences: settings.gitExecutionPreferences,
                                      gitExecutionJournal: gitExecutionJournal)
        let mavenRepositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".m2/repository", isDirectory: true)
        let gradleRepositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gradle/caches/modules-2/files-2.1", isDirectory: true)
        let javaMavenOperations = providedJavaMavenOperations ?? RustJavaMavenOperations(
            core: rustCore,
            metadataRepositoryURLs: [mavenRepositoryURL, gradleRepositoryURL]
        )
        let fileStorage = MacFileStorage()
        let workspaceLanguageServerPreferences = MacWorkspaceLanguageServerPreferencesStore(store: store)
        let directoryMarkStore = WorkspaceDirectoryMarkStore(store: store)
        let runConfigurationStore = MacRunConfigurationStore(
            core: rustCore,
            storage: fileStorage,
            preferences: store
        )
        self.runConfigurationStore = runConfigurationStore
        let debugBreakpointStore = MacDebugBreakpointStore(store: store)
        let debugSteppingFilterStore = MacDebugSteppingFilterStore(store: store)
        let fileOperations = MacWorkspaceFileOperations()
        let processRunner = MacProcessRunner(logging: applicationLogging)
        let secureStore = MacLocalSecretStore()
        let databaseSecureStore = MacKeychainSecureStore(
            service: fileStorage.identity.keychainService("database"),
            legacyStore: secureStore
        )
        let githubService = GitHubService(
            core: RustGitHubCore(bridge: rustCore),
            transport: MacGitHubHTTPTransport(),
            configuration: MacGitHubConfiguration(),
            secureStore: MacKeychainSecureStore(service: fileStorage.identity.keychainService("github")),
            git: MacGitHubGitOperations(core: rustCore)
        )
        let platformUI = providedPlatformUI ?? MacPlatformUI()
        let logWindowID = UUID().uuidString
        let diagnosticsExportService = Self.makeDiagnosticsExportService(
            fileStorage: fileStorage,
            processRunner: processRunner,
            core: rustCore,
            applicationLogging: applicationLogging
        )
        let codexConfigurationSource = MacCodexConfigurationSource()
        let claudeConfigurationSource = MacClaudeConfigurationSource()
        let aiConfigurationSources: [any AIConfigurationSource] = providedAIConfigurationSources ?? [
            codexConfigurationSource,
            claudeConfigurationSource
        ]
        let credentialResolver = MacAIProviderCredentialResolver(
            localStore: secureStore,
            configurationSources: aiConfigurationSources
        )
        let ideCapabilityRegistry = IdeCapabilityRegistry()
        let languageExecutionHost = MacLanguageExecutionHost(processRegistry: processRegistry)
        let databaseSidecarURL = MacDatabaseSidecarLocator(fileStorage: fileStorage).executableURL()
        let moduleStore = providedModuleStore ?? MacModuleConfigurationStore(store: store)
        // Database is now an internal on-demand workspace feature, so an old
        // plugin-market preference must not leave the workspace inaccessible.
        if moduleStore.enabledState(for: .database) == false {
            moduleStore.setEnabledState(true, for: .database)
        }
        let moduleRuntime = ModuleRuntime(
            configurationStore: moduleStore,
            recoveryStore: moduleStore,
            launchMode: moduleLaunchMode
        )
        moduleLifecycleCoordinator = ModuleLifecycleCoordinator(runtime: moduleRuntime)
        let declarativePluginOperations = RustDeclarativePluginOperations(core: rustCore)
        let pluginPackageStore = MacPluginPackageStore(
            fileStorage: fileStorage,
            validator: declarativePluginOperations
        )
        let pluginSettings = MacPluginSettingsStore(store: store)
        let pluginLaunchResolver = MacPluginLanguageServerLaunchResolver(
            planner: declarativePluginOperations,
            directories: MacPluginStateDirectories(fileStorage: fileStorage),
            settings: pluginSettings
        )
        let pluginStartup = MacPluginStartupLoader(
            packageStore: pluginPackageStore,
            validateUI: { _ = try WorkbenchModuleUIComposition.registry(for: $0) }
        ).load(recoveryStore: moduleStore)
        let bundledLanguageManifests = BundledLanguagePluginCatalog.manifests
        let moduleRegistry = ModuleRegistry(
            runtime: moduleRuntime,
            pluginManifests: BuiltInPluginCatalog.manifests
                + bundledLanguageManifests
                + pluginStartup.registeredManifests
        )
        do {
            try moduleRegistry.register(ModuleFactory(manifest: WorkspaceFoundationModule.moduleManifest, contributions: WorkspaceFoundationModule.moduleContributions) {
                WorkspaceFoundationModule(makeGraph: {
                    let owner = WorkspaceModuleResourceOwner()
                    return owner
                })
            })
            try moduleRegistry.register(ModuleFactory(
                manifest: AIAssistanceModule.moduleManifest,
                contributions: AIAssistanceModule.moduleContributions
            ) {
                AIAssistanceModule(
                    transportFactory: { MacURLSessionTransport() },
                    credentialResolver: credentialResolver
                )
            })
            try moduleRegistry.register(ModuleFactory(
                manifest: AgentConversationModule.moduleManifest,
                contributions: AgentConversationModule.moduleContributions
            ) {
                AgentConversationModule(
                    transportFactory: { MacACPAgentTransport() },
                    historyPersistence: MacAgentHistoryPersistence(store: store),
                    historyExporter: MacAgentHistoryExporter(storage: fileStorage),
                    statisticsPersistence: MacAgentSessionStatisticsPersistence(store: store)
                )
            })
            try moduleRegistry.register(ModuleFactory(manifest: DatabaseModule.moduleManifest, contributions: DatabaseModule.moduleContributions) {
                DatabaseModule(
                    processRunner: processRunner,
                    executableURL: databaseSidecarURL,
                    preferenceStore: MacDatabasePreferenceStore(store: store),
                    secureStore: MacKeychainSecureStore(
                        service: fileStorage.identity.keychainService("database"),
                        legacyStore: MacLocalSecretStore()
                    ),
                    recoveryStore: MacDatabaseRecoveryStore(fileStorage: fileStorage),
                    fileStorage: fileStorage
                )
            })
            try moduleRegistry.register(ModuleFactory(manifest: TerminalModule.moduleManifest, contributions: TerminalModule.moduleContributions) {
                TerminalModule(
                    terminalFactory: { MacTerminalTransport(scrollbackLines: settings.terminalScrollbackLines) },
                    shellDiscovery: { MacTerminalTransport.availableShells() }
                )
            })
        } catch {
            preconditionFailure("Invalid built-in module graph: \(error.localizedDescription)")
        }
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: store,
            toolDiscovery: MacRuntimeToolDiscovery()
        )
        let languageServerCacheDirectory = fileStorage.cacheDirectory()
            .appendingPathComponent("Lithe/language-servers", isDirectory: true)
        // Native integrations a plugin's language server may name in its
        // manifest. Each one owns everything specific to its server; the code
        // below only routes by the declared ID.
        let languageServerHostIntegrations = MacLanguageServerHostIntegrations([
            MacJdtHostIntegration(
                launchResolver: pluginLaunchResolver,
                runtimeService: runtimeService,
                workspaceState: MacJdtWorkspaceState(
                    core: rustCore,
                    cacheDirectoryURL: languageServerCacheDirectory
                )
            )
        ])
        languageServerHostIntegrations.pluginsDidLoad(
            pluginStartup.registeredPlugins,
            installed: pluginStartup.scanSucceeded ? pluginStartup.installedPlugins : nil
        )
        // Provider processes of plugin build systems, one per plugin, build
        // system, and workspace. Created eagerly so the language sessions
        // can be connected; nothing starts until a model or dependency load.
        let buildProviderSessions = MacBuildProviderSessions(
            launchResolver: pluginLaunchResolver,
            tools: MacBuildToolResolver(runtime: runtimeService, processRunner: processRunner, fileStorage: fileStorage),
            versionChecker: declarativePluginOperations,
            runtime: runtimeService,
            core: rustCore,
            processRegistry: processRegistry
        )
        let rustLanguageProviderCatalogSource = RustLanguageProviderCatalogSource(core: rustCore)
        // Installation owns the process-backed language boundary even when a
        // package is disabled, quarantined, or failed to load. Only the active
        // manifests below contribute factories; keeping static ownership here
        // prevents the host from silently restoring its legacy process path.
        let installedLanguageSupports = BundledLanguagePluginCatalog.languageSupports
            + pluginStartup.installedLanguageSupports
        let languageProviderCatalogSource = PluginLanguageProviderCatalogSource(
            base: rustLanguageProviderCatalogSource,
            languageSupports: installedLanguageSupports
        )
        let languageProviderCatalogSnapshot = languageProviderCatalogSource.load()
        let languageProviderCatalog = languageProviderCatalogSnapshot.catalog
        let pluginLanguageIDs = Set(installedLanguageSupports.map(\.id))
        // A package may declare, through its host integration, that the host
        // keeps providing a feature of its language. Everything else of an
        // installed language needs the package's own module.
        let hostLanguageCapabilities = Dictionary(
            installedLanguageSupports.map { ($0.id, $0.hostCapabilities) },
            uniquingKeysWith: { $0.intersection($1) }
        )
        let runExtensionLanguageIDs = installedLanguageSupports
            .languageIDs(requiringExtensionFor: .run)
        let testExtensionLanguageIDs = installedLanguageSupports
            .languageIDs(requiringExtensionFor: .testing)
        // Build the catalog once so every standard runtime consumes the
        // language-pack launch metadata instead of maintaining a second map.
        let languagePackDefinitions = LanguagePackRegistry.standard(
            catalog: languageProviderCatalog,
            extensionRequiredProviderIDs: pluginLanguageIDs,
            hostCapabilities: hostLanguageCapabilities
        )
        let debugLaunches = Dictionary(
            uniqueKeysWithValues: languagePackDefinitions.packs.compactMap { pack in
                pack.debugAdapterLaunch.map { (pack.descriptor.id, $0) }
            }
        )
        let languagePackRegistry = languagePackDefinitions
        let runToolchainRegistry = languagePackRegistry.toolchainRegistry
        do {
            try moduleRegistry.register(ModuleFactory(manifest: LanguageIntelligenceModule.moduleManifest, contributions: LanguageIntelligenceModule.moduleContributions) {
                LanguageIntelligenceModule(makeGraph: {
                    let tools = LanguageServerToolService(
                        runtimeService: runtimeService,
                        commandRunner: processRunner,
                        settingsStore: MacLanguageToolSettingsStore(store: store),
                        versionChecker: declarativePluginOperations
                    )
                    let runtimeFactory = StdioLanguageProviderRuntimeFactory(
                        runtimeService: runtimeService,
                        languageServerCore: rustCore,
                        languageServerExecutableResolver: { tools.executableURL(for: $0) },
                        hostIntegrationResolver: { languageServerHostIntegrations.launch(for: $0) },
                        languageServerLaunchResolver: { source, rootURL in
                            try pluginLaunchResolver.resolve(source, workspaceRootURL: rootURL)
                        },
                        languageServerCacheDirectory: languageServerCacheDirectory,
                        processRegistry: processRegistry
                    )
                    let runtimes = languagePackDefinitions.packs
                        .filter { !pluginLanguageIDs.contains($0.descriptor.id) }
                        .compactMap {
                        runtimeFactory.makeRuntime(for: $0.descriptor)
                    }
                    let registry = LanguagePackRegistry.standard(
                        catalog: languageProviderCatalog,
                        runtimes: runtimes,
                        extensionRequiredProviderIDs: pluginLanguageIDs,
                        hostCapabilities: hostLanguageCapabilities
                    )
                    let sessions = LanguageToolingSessionManager(
                        catalog: registry.catalog,
                        runtimes: registry.toolingRuntimes,
                        runtimeFactory: runtimeFactory,
                        builtinCore: rustCore,
                        extensionRequiredProviderIDs: pluginLanguageIDs,
                        isLanguageServerEnabled: { providerID, workspaceURL in
                            !workspaceLanguageServerPreferences.disabledProviderIDs(for: workspaceURL)
                                .contains(providerID)
                        },
                        workspaceFingerprintProvider: { descriptor, workspaceRootURL in
                            try languageServerHostIntegrations.workspaceFingerprint(
                                for: descriptor,
                                workspaceRootURL: workspaceRootURL
                            )
                        },
                        workspaceStateResetter: { descriptor, workspaceRootURL, fingerprint in
                            try languageServerHostIntegrations.resetWorkspaceState(
                                for: descriptor,
                                workspaceRootURL: workspaceRootURL,
                                fingerprint: fingerprint
                            )
                        },
                        workspaceStateCleaner: { descriptor, workspaceRootURL, fingerprint in
                            try languageServerHostIntegrations.pruneWorkspaceState(
                                for: descriptor,
                                workspaceRootURL: workspaceRootURL,
                                fingerprint: fingerprint
                            )
                        }
                    )
                    sessions.onLogEvent = { provider, operation, level, message, detail in
                        applicationLogging?.record(level: level == "warning" ? "warn" : level,
                            scope: "language.\(provider)", message: message,
                            fields: ["operation_id": operation ?? "", "window_id": logWindowID, "detail": detail ?? ""])
                    }

                    let graph = LanguageIntelligenceFeatureGraph(
                        sessions: sessions,
                        tools: tools
                    )
                    return graph
                })
            })
        } catch {
            preconditionFailure("Invalid language module graph: \(error.localizedDescription)")
        }
        do {
            try moduleRegistry.register(ModuleFactory(manifest: ExecutionModule.moduleManifest, contributions: ExecutionModule.moduleContributions) {
                ExecutionModule(makeGraph: {
                    let executableResolver = providedRunExecutableResolver ?? RunExecutableResolver(
                        runtimeService: runtimeService,
                        toolchainRegistry: runToolchainRegistry,
                        metadataResolver: ProcessRunToolchainMetadataResolver(processRunner: processRunner)
                    )
                    let buildSystemPlugins = pluginStartup.registeredPlugins.filter { !$0.descriptor.buildSystems.isEmpty }
                    let buildSystems = buildSystemPlugins.isEmpty ? nil : BuildSystemService(
                        planner: RustBuildSystemOperations(core: rustCore),
                        tools: MacBuildToolResolver(
                            runtime: runtimeService,
                            processRunner: processRunner,
                            fileStorage: fileStorage
                        ),
                        optionsStore: MacBuildOptionsStore(store: store),
                        stateLocator: MacBuildSystemStateLocator(
                            directories: MacPluginStateDirectories(fileStorage: fileStorage),
                            fileStorage: fileStorage
                        ),
                        runner: MacBuildCommandRunner(processRegistry: processRegistry),
                        providers: buildProviderSessions,
                        sources: {
                            // Enablement is read on every detection, so turning a
                            // plugin off takes its build systems away at once.
                            buildSystemPlugins.compactMap { plugin -> BuildSystemPluginSource? in
                                let id = plugin.descriptor.id.rawValue
                                guard let snapshot = try? moduleRuntime.snapshot(for: .buildSystemsExtension(id)),
                                      snapshot.state != .disabled,
                                      !snapshot.isQuarantined,
                                      !snapshot.isSuppressedBySafeMode else { return nil }
                                return BuildSystemPluginSource(
                                    pluginID: id,
                                    manifest: plugin.descriptor.normalizedManifest,
                                    packageURL: plugin.packageURL,
                                    buildSystems: plugin.descriptor.buildSystems
                                )
                            }
                        }
                    )
                    let graph = ExecutionFeatureGraph(
                        maven: MavenService(
                            runtimeService: runtimeService,
                            process: MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution),
                            dependencyProcess: MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution),
                            mavenOperations: javaMavenOperations,
                            configurationStore: MacMavenConfigurationStore(storage: fileStorage),
                            dependencyOutputs: MacMavenDependencyOutputStore()
                        ),
                        run: RunService(
                            runtime: runtimeService,
                            process: MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution),
                            processFactory: { MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution) },
                            fileAccess: MacRunFileAccess(storage: fileStorage),
                            preferences: MacRunPreferenceStore(store: store),
                            serverPortParser: javaMavenOperations,
                            runConfigurationOperations: providedRunConfigurationOperations ?? runConfigurationStore,
                            executableResolver: executableResolver,
                            languageProviderCatalog: languagePackRegistry.catalog,
                            languageRunProviders: languagePackRegistry.runProviders,
                            extensionRequiredLanguageIDs: runExtensionLanguageIDs,
                            languageSupports: installedLanguageSupports,
                            dependencyStore: MacWorkspaceDependencyStore(storage: fileStorage),
                            javaLaunchArgumentPreparer: rustCore
                        ),
                        tests: LanguageTestService(
                            catalog: languagePackRegistry.catalog,
                            registry: languagePackRegistry.testProviders,
                            executableResolver: executableResolver,
                            processFactory: { MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution) },
                            extensionRequiredLanguageIDs: testExtensionLanguageIDs,
                            resultParser: { output, rootURL, reports in
                                javaMavenOperations.mavenTestResults(
                                    output: output,
                                    projectRoot: rootURL,
                                    reports: reports
                                )
                            }
                        ),
                        buildSystems: buildSystems
                    )
                    let mavenFeature = graph.mavenFeature
                    graph.run.configureLanguageDependencyProvider { [weak mavenFeature] languageID, workspace, serviceID in
                        let capabilityID: ModuleCapabilityID = languageID == "java"
                            ? .languageIntelligence : .languageServerExtension(languageID)
                        guard let provider = moduleRuntime.capability(capabilityID)
                            as? any LanguageDependencyProviding else { return nil }
                        let snapshot = provider.dependencySnapshot(workspaceURL: workspace, serviceID: serviceID)
                        guard languageID == "java", snapshot?.dependencyRoots.isEmpty != false,
                              let mavenFeature,
                              let project = mavenFeature.project,
                              project.rootURL.standardizedFileURL == workspace.standardizedFileURL,
                              !mavenFeature.isProjectReloadRequired else { return snapshot }
                        let modules = ["."] + project.allModules.map(\.relativePath)
                        let roots = modules.flatMap {
                            mavenFeature.resolvedDependencyArtifactPaths(
                                modulePath: $0,
                                defaultRepositoryURL: mavenRepositoryURL
                            )
                        }.filter { fileStorage.fileExists(at: $0) }
                        guard !roots.isEmpty else { return snapshot }
                        return LanguageDependencySnapshot(
                            sourceRoots: snapshot?.sourceRoots ?? [],
                            binaryRoots: snapshot?.binaryRoots ?? [],
                            dependencyRoots: Array(Set(roots)).sorted { $0.path < $1.path },
                            virtualDocuments: snapshot?.virtualDocuments ?? []
                        )
                    }
                    return graph
                })
            })
            try moduleRegistry.register(ModuleFactory(manifest: DebugModule.moduleManifest, contributions: DebugModule.moduleContributions) {
                DebugModule(makeGraph: {
                    let debugFactories: [String: () -> (any DebugAdapterSession)?] = [
                        "java": {
                            CoreDebugAdapterProtocolSession(
                                adapterID: "java",
                                transport: MacJavaDebugAdapterTransport(
                                    portResolver: { rootURL in
                                        guard let capability = try await moduleRuntime
                                            .activateCapability(.languageIntelligence)
                                            as? LanguageIntelligenceCapability else {
                                            throw MacJavaDebugAdapterTransport.TransportError
                                                .languageIntelligenceUnavailable
                                        }
                                        return try await capability.sessions.startJavaDebugServer(
                                            rootURL: rootURL
                                        )
                                    }
                                ),
                                core: rustCore,
                                deadlineScheduler: MacDebugOperationDeadlineScheduler()
                            )
                        },
                        "go": {
                            guard let executable = runtimeService.executableOnPath("dlv") else { return nil }
                            return DebugAdapterProtocolSession(
                                adapterID: "go",
                                transport: MacDlvDebugAdapterTransport(
                                    executableURL: executable,
                                    environment: runtimeService.processEnvironment(),
                                    process: MacRawProcessSession()
                                )
                            )
                        },
                        "node": {
                            guard let executable = runtimeService.executableOnPath("node") else { return nil }
                            let environment = runtimeService.processEnvironment()
                            return DebugAdapterProtocolSession(
                                adapterID: "pwa-node",
                                transport: MacNodeDebugAdapterTransport(
                                    nodeExecutableURL: executable,
                                    locator: MacJavaScriptDebugAdapterLocator(
                                        environment: environment,
                                        executableOnPath: { runtimeService.executableOnPath($0) }
                                    ),
                                    process: MacRawProcessSession()
                                )
                            )
                        }
                    ]
                    let debugRuntimeFactory = DebugAdapterRuntimeFactory(
                        runtimeService: runtimeService,
                        transportFactory: { executableURL, arguments, environment in
                            MacProcessDebugAdapterTransport(
                                executableURL: executableURL,
                                arguments: arguments,
                                environment: environment,
                                process: MacRawProcessSession()
                            )
                        },
                        launches: debugLaunches,
                        sessionFactories: debugFactories
                    )
                    let adapterSessions = DebugAdapterSessionManager(
                        providers: languageProviderCatalog.debugProviders,
                        makeSession: { descriptor, rootURL in
                            debugRuntimeFactory.makeSession(
                                for: descriptor,
                                rootURL: rootURL
                            )
                        }
                    )
                    let graph = DebugFeatureGraph(
                        adapterSessions: adapterSessions,
                        breakpointPersistence: debugBreakpointStore,
                        breakpointRelocator: rustCore,
                        steppingFilterResolver: rustCore,
                        steppingFilterPersistence: debugSteppingFilterStore
                    )
                    return graph
                })
            })
        } catch {
            preconditionFailure("Invalid execution/debug module graph: \(error.localizedDescription)")
        }
        let gitOperations = RustGitOperations(core: rustCore)
        let defaultWorkspaceOperations = RustWorkspaceOperations(core: rustCore)
        let workspaceOperations: any WorkspaceOperations = providedWorkspaceOperations ?? defaultWorkspaceOperations
        let searchOperations: any SearchOperations =
            (providedWorkspaceOperations as? any SearchOperations) ?? defaultWorkspaceOperations
        let gitWatchContextProvider: any GitWatchContextProviding =
            providedGitWatchContextProvider ?? RustGitWatchContextProvider(core: rustCore)
        let localHistoryOperations = RustLocalHistoryOperations(core: rustCore)
        let markdownRenderer = RustMarkdownRendering(core: rustCore)
        let markdownImageImporter = MarkdownImageImportService(storage: fileStorage)
        do {
            try moduleRegistry.register(ModuleFactory(manifest: GitModule.moduleManifest, contributions: GitModule.moduleContributions) {
                GitModule(
                    operations: gitOperations,
                    shelfStorage: MacGitShelfStorage(storage: fileStorage),
                    performanceLogger: gitPerformanceLogger ?? NullGitPerformanceLogger(),
                    patchFileAccess: MacGitPatchFileAccess(storage: fileStorage),
                    executionJournal: gitExecutionJournal,
                    changelistStorage: MacGitChangelistStorage(store: store)
                )
            })
            try moduleRegistry.register(ModuleFactory(manifest: SearchModule.moduleManifest, contributions: SearchModule.moduleContributions) {
                SearchModule(operations: searchOperations)
            })
            try moduleRegistry.register(ModuleFactory(manifest: HistoryModule.moduleManifest, contributions: HistoryModule.moduleContributions) {
                HistoryModule(
                    workspaceAccess: MacLocalHistoryWorkspaceAccess(workspaceOperations: workspaceOperations, fileOperations: fileOperations),
                    storage: MacLocalHistoryStorage(storage: fileStorage),
                    operations: localHistoryOperations
                )
            })
            for factory in Self.declarativePluginFactories(
                pluginStartup.registeredPlugins,
                executionHost: languageExecutionHost,
                planner: declarativePluginOperations,
                launchResolver: pluginLaunchResolver
            ) {
                try moduleRegistry.register(factory)
            }
            for specification in BundledLanguagePluginCatalog.specifications {
                if specification.supportsLanguageServer {
                    let languageServerModule = BundledLanguageServerModule(specification: specification)
                    try moduleRegistry.register(ModuleFactory(manifest: languageServerModule.manifest) {
                        BundledLanguageServerModule(specification: specification)
                    })
                }
                if specification.supportsExecution {
                    let executionModule = BundledLanguageExecutionModule(
                        languageID: specification.id,
                        executionHost: languageExecutionHost
                    )
                    try moduleRegistry.register(ModuleFactory(manifest: executionModule.manifest) {
                        BundledLanguageExecutionModule(
                            languageID: specification.id,
                            executionHost: languageExecutionHost
                        )
                    })
                }
            }
            try moduleRegistry.validate()
        } catch {
            preconditionFailure("Invalid workspace module graph: \(error.localizedDescription)")
        }
        // Keep binary formats default-denied. Future format support must be
        // registered explicitly at this composition boundary.
        let binaryFileViewerRegistry = BinaryFileViewerRegistry()
        let pluginWebPages = PluginWebPages(
            windows: MacPluginWebContent.windows(pluginStartup.registeredPlugins),
            stateStore: MacPluginWebStateStore(
                directories: MacPluginStateDirectories(fileStorage: fileStorage),
                fileStorage: fileStorage
            ),
            prompt: MacPluginWebConsentPrompt.confirm
        )
        pluginWebPageLifecycle.register(pluginWebPages)
        let pluginManager = MacPluginManager(
            packageStore: pluginPackageStore,
            moduleRuntime: moduleRuntime,
            configurationStore: moduleStore,
            settings: pluginSettings,
            launchMode: moduleLaunchMode,
            startup: pluginStartup,
            managedBuiltInPlugins: bundledLanguageManifests,
            invalidateWebPages: { id in pluginWebPageLifecycle.disable(id.rawValue) },
            enableWebPages: { id in pluginWebPageLifecycle.enable(id.rawValue) },
            beforePackageReplacement: { id in
                pluginWebPageLifecycle.packageWillChange(id.rawValue)
                // The running provider still executes the old files; the
                // build systems' plugin list is a startup snapshot and does
                // not see the replacement.
                buildProviderSessions.stopProviders(ofPlugin: id.rawValue)
            }
        )
        let pluginMarketplaceTransport: any MacPluginMarketplaceTransport
        #if DEBUG
        pluginMarketplaceTransport = MacPluginMarketplaceFixtureTransport.fromEnvironment()
            ?? MacURLSessionPluginMarketplaceTransport()
        #else
        pluginMarketplaceTransport = MacURLSessionPluginMarketplaceTransport()
        #endif
        let pluginMarketplace = MacPluginMarketplaceService(
            evaluator: RustPluginMarketplaceOperations(core: rustCore),
            packageStore: pluginPackageStore,
            downloader: MacPluginPackageDownloader(
                transport: pluginMarketplaceTransport,
                temporaryDirectory: fileStorage.temporaryDirectory()
            ),
            transport: pluginMarketplaceTransport,
            applicationSupportDirectory: fileStorage.applicationSupportDirectory(),
            cacheDirectory: fileStorage.cacheDirectory(),
            // Read-only input shipped with the app; fetched indexes go to
            // the cache directory above, never into the bundle.
            bundledOfficialIndexURL: Bundle.main.resourceURL?
                .appendingPathComponent("PluginMarketplace/index.json", isDirectory: false),
            diskImporter: MacPluginDiskPackageImporter(temporaryDirectory: fileStorage.temporaryDirectory())
        )
        let pluginCatalog: ValidatedPluginCatalog
        do {
            pluginCatalog = try ValidatedPluginCatalog(
                manifests: BuiltInPluginCatalog.manifests + bundledLanguageManifests + pluginStartup.registeredManifests,
                hostVersion: BuiltInPluginCatalog.hostVersion
            )
        } catch {
            preconditionFailure("Invalid installed plugin catalog: \(error.localizedDescription)")
        }
        services = AppServices(
            moduleRuntime: moduleRuntime,
            pluginManager: pluginManager,
            pluginMarketplace: pluginMarketplace,
            pluginCatalog: pluginCatalog,
            pluginUIIconResources: pluginStartup.iconResources,
            pluginWebPages: pluginWebPages,
            languageProviderCatalogSource: languageProviderCatalogSource,
            workspaceLanguageServerPreferences: workspaceLanguageServerPreferences,
            languageProviderCatalogSnapshot: languageProviderCatalogSnapshot,
            debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver(
                fileStorage: fileStorage,
                javaTestLaunchResolver: rustCore,
                javaExecutablePath: { [runtimeService] runtime in
                    runtimeService.javaExecutableURL(forDebugging: runtime)?.path
                }
            ),
            debugPortAvailabilityChecker: MacDebugPortAvailabilityChecker(),
            javaTestResultServerFactory: { MacJavaTestResultServer() },
            debugBreakpointPersistence: debugBreakpointStore,
            workspaceOperations: workspaceOperations,
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: rustCore),
            lineEditing: RustLineEditing(core: rustCore),
            javaMavenOperations: javaMavenOperations,
            markdownRenderer: markdownRenderer,
            markdownImageImporter: markdownImageImporter,
            store: store,
            fileStorage: fileStorage,
            fileOperations: fileOperations,
            agentEditRestorer: MacAgentEditRestorer(fileOperations: fileOperations),
            binaryFileViewerRegistry: binaryFileViewerRegistry,
            projectRuntimeService: runtimeService,
            gitWatchContextProvider: gitWatchContextProvider,
            githubService: githubService,
            secureStore: secureStore,
            databaseSecureStore: databaseSecureStore,
            diagnosticsExportService: diagnosticsExportService,
            credentialResolver: credentialResolver,
            agentManagement: RustAgentManagementService(core: rustCore),
            agentProviderConfigurationParser: MacAgentProviderConfigurationParser(core: rustCore),
            aiConfigurationSources: aiConfigurationSources,
            recentProjectsStore: RecentProjectsStore(store: store),
            recentProjectBranchReader: MacRecentProjectBranchReader(storage: fileStorage),
            workspaceSessionStore: WorkspaceSessionStore(store: store),
            directoryMarkStore: directoryMarkStore,
            workbenchLayoutStore: WorkbenchLayoutStore(store: store),
            workbenchBackgroundPlatform: MacWorkbenchBackgroundPlatform(store: store),
            directoryWatcherFactory: MacDirectoryWatcherFactory(),
            platformUI: platformUI,
            shortcutDetectorFactory: MacShortcutDetectorFactory(),
            debugPerformanceSampler: MacDebugPerformanceSampler(processRegistry: processRegistry),
            testJVMPerformance: MacTestJVMPerformance(processRegistry: processRegistry)
        )
        services.ideCapabilityRegistry = ideCapabilityRegistry
        services.ideHostTransport = MacIdeHostTransport(core: rustCore, storage: fileStorage)
        services.mcpConfigurationStore = MacAgentMcpConfigurationStore(
            core: rustCore, storage: fileStorage
        )
        services.connectBuildProviderLanguageSessions = { sessions in
            buildProviderSessions.languageSessions = sessions
        }
        services.processExitCoordinator = ProcessExitCoordinator(
            core: RustProcessLifecycleDecider(core: rustCore),
            presenter: MacProcessExitConfirmationPresenter.shared
        )
        moduleLifecycleCoordinator.start()
        Task {
            do {
                try await moduleRegistry.startEagerModules()
                applicationLogging?.record(level: "info", scope: "plugins.lifecycle", message: "eager modules started", fields: [:])
            } catch {
                applicationLogging?.record(level: "error", scope: "plugins.lifecycle", message: "module activation failed",
                    fields: ["error": error.localizedDescription])
            }
        }
    }

    /// Host-owned module factories for declarative plugins. The plugins'
    /// declarations configure the same language-server and execution modules
    /// the host uses for bundled languages; no plugin code is loaded.
    static func declarativePluginFactories(
        _ plugins: [InstalledPluginPackage],
        executionHost: any LanguageExecutionHostProviding,
        planner: any DeclarativeExecutionPlanning,
        launchResolver: MacPluginLanguageServerLaunchResolver? = nil
    ) -> [ModuleFactory] {
        plugins.flatMap { installed -> [ModuleFactory] in
            let descriptor = installed.descriptor
            let modules = Dictionary(uniqueKeysWithValues: descriptor.pluginManifest.modules.map {
                ($0.manifest.id, $0.manifest)
            })
            let languageNames = Dictionary(uniqueKeysWithValues: (descriptor.pluginManifest.languageSupports ?? []).map {
                ($0.id, $0.displayName)
            })
            let servers = descriptor.languageServers.compactMap { server -> ModuleFactory? in
                guard let manifest = modules[.languageServerExtension(server.languageID)] else { return nil }
                // Plugin API 2 arguments are templates: Rust Core expands them
                // when the server starts. API 1 arguments stay literal and
                // keep the launch path they have always used.
                let launchSource = server.expandsLaunchTemplates
                    ? DeclarativeLanguageServerLaunchSource(
                        pluginID: descriptor.id.rawValue,
                        languageID: server.languageID,
                        manifest: descriptor.normalizedManifest,
                        packageURL: installed.packageURL
                    )
                    : nil
                // An unexpandable probe is left empty, so the server is found
                // unverified and the launch itself reports the real problem.
                let probe = launchSource.map {
                    (try? launchResolver?.executableProbe(for: $0)) ?? .init()
                } ?? .init(validationArguments: server.validationArguments)
                let configuration = LanguageServerExtensionConfiguration(
                    languageID: server.languageID,
                    displayName: languageNames[server.languageID] ?? server.languageID,
                    executableNames: server.executableNames,
                    arguments: server.arguments,
                    validationArguments: probe.validationArguments,
                    runtimeTools: server.runtimeTools,
                    // A packaged server, or the runtime a plugin ships for
                    // its server, is read in place from the installed,
                    // read-only version directory of this plugin only.
                    executableURL: server.packagedRelativePath.map {
                        installed.packageURL.appendingPathComponent($0).standardizedFileURL
                    } ?? probe.packagedRuntimeURL,
                    languageIdentifier: server.languageIdentifier,
                    launchSource: launchSource,
                    executableVersionRequirement: probe.versionRequirement,
                    hostIntegrationID: server.hostIntegrationID,
                    launchRuntimeTool: server.launchRuntimeTool
                )
                return ModuleFactory(manifest: manifest) {
                    BundledLanguageServerModule(manifest: manifest, configuration: configuration)
                }
            }
            let templates = DeclarativeExecutionTemplates(
                manifest: descriptor.normalizedManifest,
                planner: planner
            )
            let executions = descriptor.executionProviders.compactMap { provider -> ModuleFactory? in
                guard let manifest = modules[.languageExecutionExtension(provider.languageID)] else { return nil }
                return ModuleFactory(manifest: manifest) {
                    BundledLanguageExecutionModule(
                        manifest: manifest,
                        languageID: provider.languageID,
                        executionHost: executionHost,
                        templates: templates
                    )
                }
            }
            // The build-systems module also carries the enabled state; the
            // execution module reads it before handing the plugin to Rust Core.
            let workbench = descriptor.pluginManifest.modules.filter {
                !$0.contributions.isEmpty || $0.manifest.id == .buildSystemsExtension(descriptor.id.rawValue)
            }.map { declaration in
                ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
                    DeclarativeWorkbenchModule(declaration: declaration)
                }
            }
            return servers + executions + workbench
        }
    }
}
