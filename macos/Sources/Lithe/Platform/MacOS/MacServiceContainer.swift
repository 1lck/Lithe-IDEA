import Foundation
import LitheAIAssistanceModule
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
@MainActor
final class MacServiceContainer {
    let services: AppServices
    let runConfigurationStore: MacRunConfigurationStore
    let moduleLifecycleCoordinator: ModuleLifecycleCoordinator

    static func makeLogDirectoryProvider() -> any LogDirectoryProviding {
        MacLogDirectoryProvider()
    }

    static func makeApplicationLogWriter() -> MacApplicationLogWriter {
        MacApplicationLogWriter()
    }

    init(
        store: any KeyValueStore,
        settings: AppSettings,
        processRegistry: ManagedProcessRegistry = ManagedProcessRegistry(),
        moduleLaunchMode: ModuleLaunchMode = .normal,
        moduleStore providedModuleStore: MacModuleConfigurationStore? = nil,
        pluginRuntimeRecovery: MacPluginRuntimeRecoveryCoordinator? = nil,
        authorizationCallbackRouter providedAuthorizationCallbackRouter: MacExternalAuthorizationCallbackRouter? = nil
    ) {
        let authorizationCallbackRouter = providedAuthorizationCallbackRouter
            ?? MacExternalAuthorizationCallbackRouter()
        let rustCore = RustCoreBridge()
        let mavenRepositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".m2/repository", isDirectory: true)
        let gradleRepositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gradle/caches/modules-2/files-2.1", isDirectory: true)
        let javaMavenOperations = RustJavaMavenOperations(
            core: rustCore,
            metadataRepositoryURLs: [mavenRepositoryURL, gradleRepositoryURL]
        )
        let fileStorage = MacFileStorage()
        let runConfigurationStore = MacRunConfigurationStore(
            core: rustCore,
            storage: fileStorage,
            preferences: store
        )
        self.runConfigurationStore = runConfigurationStore
        let debugBreakpointStore = MacDebugBreakpointStore(store: store)
        let debugSteppingFilterStore = MacDebugSteppingFilterStore(store: store)
        let fileOperations = MacWorkspaceFileOperations()
        let processRunner = MacProcessRunner()
        let secureStore = MacLocalSecretStore()
        let databaseSecureStore = MacKeychainSecureStore(
            service: "app.lithe.desktop.database",
            legacyStore: secureStore
        )
        let githubService = GitHubService(
            core: RustGitHubCore(bridge: rustCore),
            transport: MacGitHubHTTPTransport(),
            configuration: MacGitHubConfiguration(),
            secureStore: MacKeychainSecureStore(service: "app.lithe.desktop.github"),
            git: MacGitHubGitOperations(core: rustCore)
        )
        let platformUI = MacPlatformUI()
        let discourseCommunityService = DiscourseCommunityService(
            core: rustCore,
            credentialStore: MacKeychainSecureStore(service: "app.lithe.desktop.linux-do"),
            platformUI: platformUI,
            callbackRouter: authorizationCallbackRouter
        )
        let codexConfigurationSource = MacCodexConfigurationSource()
        let claudeConfigurationSource = MacClaudeConfigurationSource()
        let aiConfigurationSources: [any AIConfigurationSource] = [
            codexConfigurationSource,
            claudeConfigurationSource
        ]
        let credentialResolver = MacAIProviderCredentialResolver(
            localStore: secureStore,
            configurationSources: aiConfigurationSources
        )
        let pluginHostServices = MacPluginHostServiceRegistry()
        let languageExecutionHost = MacLanguageExecutionHost(processRegistry: processRegistry)
        pluginHostServices.register(languageExecutionHost, for: .languageExecution)
        let databaseSidecarURL = MacDatabaseSidecarLocator(fileStorage: fileStorage).executableURL()
        let moduleStore = providedModuleStore ?? MacModuleConfigurationStore(store: store)
        let moduleRuntime = ModuleRuntime(
            configurationStore: moduleStore,
            recoveryStore: moduleStore,
            launchMode: moduleLaunchMode
        )
        moduleLifecycleCoordinator = ModuleLifecycleCoordinator(runtime: moduleRuntime)
        let pluginPackageStore = MacPluginPackageStore(fileStorage: fileStorage)
        let pluginStartup = MacPluginStartupLoader(
            packageStore: pluginPackageStore,
            nativeLoader: MacNativePluginLoader(
                hostContext: PluginHostContext(resolver: pluginHostServices)
            ),
            runtimeRecovery: pluginRuntimeRecovery
        ).load(policy: MacPluginLoadPolicy(
            configurationStore: moduleStore,
            recoveryStore: moduleStore,
            launchMode: moduleLaunchMode
        ))
        let bundledLanguageManifests = BundledLanguagePluginCatalog.manifests
        let moduleRegistry = ModuleRegistry(
            runtime: moduleRuntime,
            pluginManifests: BuiltInPluginCatalog.manifests
                + bundledLanguageManifests
                + pluginStartup.activeNativeManifests
        )
        do {
            try moduleRegistry.register(ModuleFactory(manifest: WorkspaceFoundationModule.moduleManifest) {
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
            try moduleRegistry.register(ModuleFactory(manifest: DatabaseModule.moduleManifest, contributions: DatabaseModule.moduleContributions) {
                DatabaseModule(
                    processRunner: processRunner,
                    executableURL: databaseSidecarURL,
                    preferenceStore: MacDatabasePreferenceStore(store: store),
                    secureStore: MacKeychainSecureStore(
                        service: "app.lithe.desktop.database",
                        legacyStore: MacLocalSecretStore()
                    ),
                    recoveryStore: MacDatabaseRecoveryStore(fileStorage: fileStorage),
                    fileStorage: fileStorage
                )
            })
            try moduleRegistry.register(ModuleFactory(manifest: TerminalModule.moduleManifest, contributions: TerminalModule.moduleContributions) {
                TerminalModule(
                    terminalFactory: { MacTerminalTransport() },
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
        let rustLanguageProviderCatalogSource = RustLanguageProviderCatalogSource(core: rustCore)
        // Installation owns the process-backed language boundary even when a
        // package is disabled, quarantined, or failed to load. Only the active
        // manifests below contribute factories; keeping static ownership here
        // prevents the host from silently restoring its legacy process path.
        let installedPluginManifests = pluginStartup.installedManifests
        let installedLanguageSupports = BundledLanguagePluginCatalog.languageSupports
            + pluginStartup.installedLanguageSupports
        let languageProviderCatalogSource = PluginLanguageProviderCatalogSource(
            base: rustLanguageProviderCatalogSource,
            languageSupports: installedLanguageSupports
        )
        let languageProviderCatalogSnapshot = languageProviderCatalogSource.load()
        let languageProviderCatalog = languageProviderCatalogSnapshot.catalog
        let pluginLanguageIDs = Set(installedLanguageSupports.map(\.id))
        // Build the catalog once so every standard runtime consumes the
        // language-pack launch metadata instead of maintaining a second map.
        let languagePackDefinitions = LanguagePackRegistry.standard(
            catalog: languageProviderCatalog,
            extensionRequiredProviderIDs: pluginLanguageIDs
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
                        settingsStore: MacLanguageToolSettingsStore(store: store)
                    )
                    let languageServerCacheDirectory = fileStorage.cacheDirectory()
                        .appendingPathComponent("Lithe/language-servers", isDirectory: true)
                    let jdtWorkspaceState = MacJdtWorkspaceState(
                        core: rustCore,
                        cacheDirectoryURL: languageServerCacheDirectory
                    )
                    let jdtlsLaunchResourceResolver = MacJDTLSLaunchResourceResolver()
                    let runtimeFactory = StdioLanguageProviderRuntimeFactory(
                        runtimeService: runtimeService,
                        languageServerCore: rustCore,
                        languageServerExecutableResolver: { tools.executableURL(for: $0) },
                        languageServerRuntimeResolver: { descriptor in
                            guard descriptor.id == "java" else { return .notRequired }
                            guard let executableURL = runtimeService.javaLanguageServerExecutableURL() else {
                                return .unavailable(
                                    runtimeService.javaLanguageServerRuntimeFailureMessage()
                                        ?? "The bundled Temurin JDK 21 is not prepared."
                                )
                            }
                            return .available(executableURL)
                        },
                        jdtlsLaunchResourcesResolver: { descriptor, executableURL in
                            guard descriptor.id == "java" else { return .notRequired }
                            switch jdtlsLaunchResourceResolver.resolve(for: executableURL) {
                            case .direct(let resources):
                                return .available(resources)
                            case .wrapperFallback:
                                return .notRequired
                            case .unavailable(let message):
                                return .unavailable(message)
                            }
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
                        extensionRequiredProviderIDs: pluginLanguageIDs
                    )
                    let sessions = LanguageToolingSessionManager(
                        catalog: registry.catalog,
                        runtimes: registry.toolingRuntimes,
                        runtimeFactory: runtimeFactory,
                        builtinCore: rustCore,
                        extensionRequiredProviderIDs: pluginLanguageIDs,
                        workspaceFingerprintProvider: { descriptor, workspaceRootURL in
                            guard descriptor.id == "java" else { return nil }
                            return try jdtWorkspaceState.fingerprint(
                                at: workspaceRootURL,
                                languageServerExecutableURL: tools.executableURL(for: descriptor)
                            )
                        },
                        workspaceStateResetter: { descriptor, workspaceRootURL, fingerprint in
                            guard descriptor.id == "java" else {
                                throw CocoaError(.featureUnsupported)
                            }
                            try jdtWorkspaceState.clearIndex(
                                at: workspaceRootURL,
                                workspaceFingerprint: fingerprint
                            )
                        },
                        workspaceStateCleaner: { descriptor, workspaceRootURL, fingerprint in
                            guard descriptor.id == "java" else { return 0 }
                            return try jdtWorkspaceState.pruneExpiredCaches(
                                at: workspaceRootURL,
                                workspaceFingerprint: fingerprint
                            ).removedWorkspaceKeys.count
                        }
                    )
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
                    let executableResolver = RunExecutableResolver(
                        runtimeService: runtimeService,
                        toolchainRegistry: runToolchainRegistry,
                        metadataResolver: ProcessRunToolchainMetadataResolver(processRunner: processRunner)
                    )
                    let graph = ExecutionFeatureGraph(
                        maven: MavenService(
                            runtimeService: runtimeService,
                            process: MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution),
                            mavenOperations: javaMavenOperations
                        ),
                        run: RunService(
                            runtime: runtimeService,
                            process: MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution),
                            processFactory: { MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution) },
                            fileAccess: MacRunFileAccess(storage: fileStorage),
                            preferences: MacRunPreferenceStore(store: store),
                            serverPortParser: javaMavenOperations,
                            runConfigurationOperations: runConfigurationStore,
                            executableResolver: executableResolver,
                            languageProviderCatalog: languagePackRegistry.catalog,
                            languageRunProviders: languagePackRegistry.runProviders,
                            extensionRequiredLanguageIDs: pluginLanguageIDs
                        ),
                        tests: LanguageTestService(
                            catalog: languagePackRegistry.catalog,
                            registry: languagePackRegistry.testProviders,
                            executableResolver: executableResolver,
                            processFactory: { MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution) },
                            extensionRequiredLanguageIDs: pluginLanguageIDs
                        )
                    )
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
        let workspaceOperations = RustWorkspaceOperations(core: rustCore)
        let localHistoryOperations = RustLocalHistoryOperations(core: rustCore)
        let markdownRenderer = RustMarkdownRendering(core: rustCore)
        let markdownImageImporter = MarkdownImageImportService(storage: fileStorage)
        do {
            try moduleRegistry.register(ModuleFactory(manifest: GitModule.moduleManifest, contributions: GitModule.moduleContributions) {
                GitModule(
                    operations: gitOperations,
                    shelfStorage: MacGitShelfStorage(storage: fileStorage)
                )
            })
            try moduleRegistry.register(ModuleFactory(manifest: SearchModule.moduleManifest, contributions: SearchModule.moduleContributions) {
                SearchModule(operations: workspaceOperations)
            })
            try moduleRegistry.register(ModuleFactory(manifest: HistoryModule.moduleManifest, contributions: HistoryModule.moduleContributions) {
                HistoryModule(
                    workspaceAccess: MacLocalHistoryWorkspaceAccess(workspaceOperations: workspaceOperations, fileOperations: fileOperations),
                    storage: MacLocalHistoryStorage(storage: fileStorage),
                    operations: localHistoryOperations
                )
            })
            for pluginID in pluginStartup.factoriesByPlugin.keys.sorted() {
                for factory in pluginStartup.factoriesByPlugin[pluginID] ?? [] {
                    try moduleRegistry.register(factory)
                }
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
        let pluginManager = MacPluginManager(
            packageStore: pluginPackageStore,
            moduleRuntime: moduleRuntime,
            configurationStore: moduleStore,
            launchMode: moduleLaunchMode,
            startup: pluginStartup,
            managedBuiltInPlugins: (BuiltInPluginCatalog.manifest(forModule: .database).map { [$0] } ?? [])
                + bundledLanguageManifests
        )
        let pluginCatalog: ValidatedPluginCatalog
        do {
            pluginCatalog = try ValidatedPluginCatalog(
                manifests: BuiltInPluginCatalog.manifests + bundledLanguageManifests + installedPluginManifests,
                hostVersion: BuiltInPluginCatalog.hostVersion
            )
        } catch {
            preconditionFailure("Invalid installed plugin catalog: \(error.localizedDescription)")
        }
        services = AppServices(
            moduleRuntime: moduleRuntime,
            pluginManager: pluginManager,
            pluginCatalog: pluginCatalog,
            languageProviderCatalogSource: languageProviderCatalogSource,
            languageProviderCatalogSnapshot: languageProviderCatalogSnapshot,
            debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver(
                fileStorage: fileStorage,
                javaTestLaunchResolver: rustCore
            ),
            javaTestResultServerFactory: { MacJavaTestResultServer() },
            debugBreakpointPersistence: debugBreakpointStore,
            workspaceOperations: workspaceOperations,
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: rustCore),
            javaMavenOperations: javaMavenOperations,
            markdownRenderer: markdownRenderer,
            markdownImageImporter: markdownImageImporter,
            store: store,
            fileStorage: fileStorage,
            fileOperations: fileOperations,
            binaryFileViewerRegistry: binaryFileViewerRegistry,
            projectRuntimeService: runtimeService,
            gitWatchContextProvider: RustGitWatchContextProvider(core: rustCore),
            githubService: githubService,
            secureStore: secureStore,
            databaseSecureStore: databaseSecureStore,
            discourseCommunityService: discourseCommunityService,
            credentialResolver: credentialResolver,
            aiConfigurationSources: aiConfigurationSources,
            recentProjectsStore: RecentProjectsStore(store: store),
            workspaceSessionStore: WorkspaceSessionStore(store: store),
            workbenchLayoutStore: WorkbenchLayoutStore(store: store),
            workbenchBackgroundPlatform: MacWorkbenchBackgroundPlatform(store: store),
            directoryWatcherFactory: MacDirectoryWatcherFactory(),
            platformUI: platformUI,
            shortcutDetectorFactory: MacShortcutDetectorFactory()
        )
        moduleLifecycleCoordinator.start()
        Task { try? await moduleRegistry.startEagerModules() }
    }
}
