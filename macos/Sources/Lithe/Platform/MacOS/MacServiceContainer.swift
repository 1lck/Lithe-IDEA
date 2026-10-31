import Combine
import Foundation
import LitheAIAssistanceModule
import LitheAgentConversationModule
import LitheApplicationKernel
import LitheCoreContracts
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
    let registry: RemoteWorkspaceRegistry
    let transport: any RemoteWorkspaceTransport

    func make(
        configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) -> any DirectoryChangeSource {
        if let binding = registry.resolve(configuration.workspaceRoot)?.binding {
            return RemoteDirectoryObservation(
                configuration: configuration, visibilityRules: visibilityRules,
                binding: binding, registry: registry, transport: transport, onChange: onChange
            )
        }
        return MacDirectoryWatcher(
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
        applicationLogging: (any ApplicationLogging)? = nil,
        networkSessionProvider providedNetworkSessionProvider: MacNetworkSessionProvider? = nil
    ) {
        let pluginWebPageLifecycle = providedPluginWebPageLifecycle ?? .shared
        let gitExecutionJournal = GitExecutionJournal()
        gitExecutionJournal.onLifecycleEvent = { event in
            applicationLogging?.record(level: event.error != nil || (event.exitCode ?? 0) != 0 ? "error" : "info",
                scope: "git.execution", message: event.type,
                fields: ["operation_id": event.operationId, "duration_ms": event.durationMilliseconds.map(String.init) ?? "",
                    "exit_code": event.exitCode.map(String.init) ?? "", "error_code": event.error?.code ?? ""])
        }
        let remoteWorkspaces = RemoteWorkspaceRegistry()
        let rustCore = RustCoreBridge(gitPreferences: settings.gitExecutionPreferences,
                                      gitExecutionJournal: gitExecutionJournal,
                                      remoteWorkspaces: remoteWorkspaces)
        let mavenRepositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".m2/repository", isDirectory: true)
        let gradleRepositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gradle/caches/modules-2/files-2.1", isDirectory: true)
        let javaMavenOperations = providedJavaMavenOperations ?? RustJavaMavenOperations(
            core: rustCore,
            metadataRepositoryURLs: [mavenRepositoryURL, gradleRepositoryURL]
        )
        let fileStorage = MacFileStorage()
        // One proxy-aware session factory per process: LitheApp creates it so
        // the rollback downloader outside this container shares the policy,
        // and every transport inside resolves sessions through it per request.
        let networkSessionProvider = providedNetworkSessionProvider
            ?? MacNetworkSessionProvider(
                preferences: settings.networkProxyPreferences,
                policyResolver: { [rustCore] configuration in
                    rustCore.networkProxyPolicy(from: configuration)
                }
            )
        let proxyPasswordStore = MacKeychainSecureStore(service: fileStorage.identity.keychainService("proxy"))
        if let credential = NetworkProxyCredential.load(from: proxyPasswordStore, key: AppSettings.networkProxyPasswordKey) {
            settings.updateNetworkProxyCredential(credential)
        }
        let proxyConnectionChecker = MacNetworkProxyTester(policyResolver: { [rustCore] configuration in
            rustCore.networkProxyPolicy(from: configuration)
        })
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
        // Remote workspaces open under an empty placeholder root; both file
        // ports route every URL below such a root to the connected host.
        let remoteOperations = RustRemoteConnectionOperations(core: rustCore)
        // Core owns the OpenSSH trees; closing them at exit also stops the
        // remote servers they carry.
        MacLiveProcessGroups.application.setExitAction("remote-connections") {
            remoteOperations.closeAllBlocking()
        }
        let remoteTransport = ConnectionWatchingTransport(base: remoteOperations, registry: remoteWorkspaces)
        let fileOperations = RemoteRoutingFileOperations(
            local: MacWorkspaceFileOperations(), registry: remoteWorkspaces, transport: remoteTransport
        )
        let processRunner = MacProcessRunner(logging: applicationLogging)
        let secureStore = MacLocalSecretStore()
        let githubService = GitHubService(
            core: RustGitHubCore(bridge: rustCore),
            transport: MacGitHubHTTPTransport(sessionProvider: { [networkSessionProvider] in networkSessionProvider.acquireSession() }),
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
        let moduleStore = providedModuleStore ?? MacModuleConfigurationStore(store: store)
        let moduleRuntime = ModuleRuntime(
            configurationStore: moduleStore,
            recoveryStore: moduleStore,
            launchMode: moduleLaunchMode
        )
        moduleLifecycleCoordinator = ModuleLifecycleCoordinator(runtime: moduleRuntime)
        let declarativePluginOperations = RustDeclarativePluginOperations(core: rustCore)
        let pluginCredentials = MacPluginCredentialStore(
            servicePrefix: fileStorage.identity.keychainService("plugin-credentials")
        )
        let pluginPackageStore = MacPluginPackageStore(
            fileStorage: fileStorage,
            validator: declarativePluginOperations,
            credentials: pluginCredentials
        )
        let pluginSettings = MacPluginSettingsStore(store: store)
        let pluginLaunchResolver = MacPluginLanguageServerLaunchResolver(
            planner: declarativePluginOperations,
            directories: MacPluginStateDirectories(fileStorage: fileStorage),
            settings: pluginSettings
        )
        let debugExecutableResolver = MacPluginDebugExecutableResolver(
            planner: declarativePluginOperations,
            settings: pluginSettings
        )
        let pluginStartupLoader = MacPluginStartupLoader(
            packageStore: pluginPackageStore,
            validateUI: { _ = try WorkbenchModuleUIComposition.registry(for: $0) }
        )
        let pluginStartup = pluginStartupLoader.load(recoveryStore: moduleStore)
        // Debug adapters of plugins registered at launch, by the language they
        // debug. A language the host debugs itself keeps its own adapter.
        // Plugins that apply without a restart are in `livePlugins` instead.
        let registeredDebugAdapters = PluginDebugAdapterEntry.index(of: pluginStartup.registeredPlugins)
        let registeredQualifiedDebugAdapters = PluginDebugAdapterEntry.qualifiedIndex(of: pluginStartup.registeredPlugins)
        let debugAdapterSessionsBox = DebugAdapterSessionsBox()
        let moduleEnablement = moduleStore
        let launchMode = moduleLaunchMode
        let livePlugins = MacLivePluginRegistry(
            initial: pluginStartup.livePlugins,
            registeredManifests: pluginStartup.registeredManifests,
            makeScanStore: pluginPackageStore.makeScanStoreFactory(),
            accept: { [pluginStartupLoader] packages, registered in
                pluginStartupLoader.accept(packages, alongside: registered)
            },
            // Follows what the module graph would decide for the plugin's modules.
            isEnabled: { package in
                guard launchMode != .safeMode else { return false }
                return package.manifest.modules.allSatisfy { declaration in
                    let id = declaration.manifest.id
                    return !moduleEnablement.isQuarantined(id)
                        && (moduleEnablement.enabledState(for: id) ?? (declaration.manifest.defaultState == .enabled))
                }
            },
            didWithdraw: { package in
                // A session runs from the registration it started with.
                debugAdapterSessionsBox.stopSessions(ofPlugin: package.descriptor.id.rawValue)
            }
        )
        let liveSnapshotBox = livePlugins.snapshotBox
        // The adapter that debugs a language right now: launch-registered
        // plugins follow their module's enablement, live plugins follow the registry.
        let isLaunchRegisteredAdapterUsable: @MainActor (String) -> Bool = { pluginID in
            guard let snapshot = try? moduleRuntime.snapshot(for: .debugAdaptersExtension(pluginID)) else {
                return false
            }
            return snapshot.state != .disabled && !snapshot.isQuarantined && !snapshot.isSuppressedBySafeMode
        }
        let qualifiedDebugAdapters: @MainActor () -> [String: PluginDebugAdapterEntry] = {
            registeredQualifiedDebugAdapters.filter {
                isLaunchRegisteredAdapterUsable($0.value.plugin.descriptor.id.rawValue)
            }.merging(PluginDebugAdapterEntry.qualifiedIndex(of: liveSnapshotBox.snapshot.activePackages)) { _, live in live }
        }
        let activeDebugAdapter: @MainActor (String) -> PluginDebugAdapterEntry? = { providerID in
            if providerID.contains("/") { return qualifiedDebugAdapters()[providerID] }
            if let entry = registeredDebugAdapters[providerID],
               isLaunchRegisteredAdapterUsable(entry.plugin.descriptor.id.rawValue) {
                return entry
            }
            return liveSnapshotBox.snapshot.debugAdapters[providerID]
        }
        // A launch-registered plugin is not in the live registry, so turning its
        // debug module off reaches the running sessions through the module's
        // own state change.
        let launchRegisteredDebugModules = Dictionary(
            pluginStartup.registeredPlugins
                .filter { !$0.descriptor.debugAdapters.isEmpty }
                .map { (ModuleID.debugAdaptersExtension($0.descriptor.id.rawValue), $0.descriptor.id.rawValue) },
            uniquingKeysWith: { first, _ in first }
        )
        if !launchRegisteredDebugModules.isEmpty {
            moduleRuntime.observeEvents { event in
                guard event.name == ModuleEvent.stateChangedName,
                      let pluginID = launchRegisteredDebugModules[event.source],
                      !isLaunchRegisteredAdapterUsable(pluginID) else { return }
                debugAdapterSessionsBox.stopSessions(ofPlugin: pluginID)
            }
        }
        let pluginMarketplaceEvaluator = RustPluginMarketplaceOperations(core: rustCore)
        let pluginMarketplaceTransport: any MacPluginMarketplaceTransport
        let proxySessionProvider: @Sendable () -> MacNetworkSessionLease = { [networkSessionProvider] in networkSessionProvider.acquireSession() }
        #if DEBUG
        pluginMarketplaceTransport = MacPluginMarketplaceFixtureTransport.fromEnvironment()
            ?? MacURLSessionPluginMarketplaceTransport(sessionProvider: proxySessionProvider)
        #else
        pluginMarketplaceTransport = MacURLSessionPluginMarketplaceTransport(sessionProvider: proxySessionProvider)
        #endif
        let remotePluginPackages = MacRemotePluginPackageDeployer(
            installed: pluginStartup.registeredPlugins,
            makeStore: { architecture in
                MacPluginPackageStore(rootURL: fileStorage.applicationSupportDirectory().appendingPathComponent("Lithe/Plugins"),
                    validator: declarativePluginOperations, architecture: architecture)
            },
            evaluator: pluginMarketplaceEvaluator, transport: pluginMarketplaceTransport,
            host: remoteOperations, temporaryDirectory: fileStorage.temporaryDirectory()
        )
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
                    transportFactory: {
                        MacURLSessionTransport(sessionProvider: { [networkSessionProvider] in networkSessionProvider.acquireSession() })
                    },
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
            try moduleRegistry.register(ModuleFactory(manifest: TerminalModule.moduleManifest, contributions: TerminalModule.moduleContributions) {
                TerminalModule(
                    terminalFactory: {
                        MacTerminalTransport(
                            scrollbackLines: settings.terminalScrollbackLines,
                            preferredAppearanceIsDark: { settings.themePreference.preferredIsDark }
                        )
                    },
                    workspaceTerminalFactory: { root in
                        let renderer = MacTerminalTransport(
                            scrollbackLines: settings.terminalScrollbackLines,
                            preferredAppearanceIsDark: { settings.themePreference.preferredIsDark }
                        )
                        guard let resolved = remoteWorkspaces.resolve(root) else { return renderer }
                        return MacRemoteTerminalTransport(renderer: renderer, binding: resolved.binding,
                                                          transport: remoteOperations)
                    },
                    shellDiscovery: { MacTerminalTransport.availableShells() },
                    workspaceShellDiscovery: { root in
                        guard let resolved = remoteWorkspaces.resolve(root) else { return nil }
                        return try await MacRemoteShellDiscovery.discover(session: resolved.binding.sessionID, host: remoteOperations)
                    }
                )
            })
        } catch {
            preconditionFailure("Invalid built-in module graph: \(error.localizedDescription)")
        }
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: store,
            toolDiscovery: MacRuntimeToolDiscovery(),
            javaSelector: rustCore,
            workspaceRuntime: { root in
                guard let binding = remoteWorkspaces.binding(forRoot: root) else { return nil }
                let locator = MacRemoteRuntimeLocator(binding: binding, host: remoteOperations)
                return (locator, locator)
            }
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
        let remotePluginLaunches = MacRemotePluginLaunchPreparer(registry: remoteWorkspaces, packages: remotePluginPackages,
            host: remoteOperations, planner: declarativePluginOperations, resolver: pluginLaunchResolver, core: rustCore)
        let providerTools = MacBuildToolResolver(runtime: runtimeService, processRunner: processRunner, fileStorage: fileStorage,
            registry: remoteWorkspaces, remoteFiles: remoteOperations, remoteProcesses: remoteOperations)
        let buildProviderSessions = MacBuildProviderSessions(
            launchResolver: pluginLaunchResolver,
            tools: providerTools,
            versionChecker: declarativePluginOperations,
            runtime: runtimeService,
            core: rustCore,
            processRegistry: processRegistry,
            remoteLaunches: remotePluginLaunches
        )
        // Provider processes of plugin VCS providers, one per plugin, VCS,
        // and workspace; one starts on the first request for a detected root.
        let vcsProviderSessions = MacVcsProviderSessions(
            launchResolver: pluginLaunchResolver,
            tools: providerTools,
            versionChecker: declarativePluginOperations,
            runtime: runtimeService,
            core: rustCore,
            processRegistry: processRegistry,
            remoteLaunches: remotePluginLaunches
        )
        // Plugin backends, one per plugin for the whole application: the
        // first project window creates them, and every window registers the
        // same startup snapshot. Nothing starts until a page calls one.
        let pluginBackends = MacPluginBackendSessions.shared {
            // The former built-in database module's connections and
            // passwords move into the Database plugin from Lithe Store
            // before its backend first starts; the old data is read, never
            // changed.
            let databaseKeychain = MacKeychainSecureStore(service: fileStorage.identity.keychainService("database"))
            let databaseMigration = MacDatabasePluginMigration(
                preferences: store,
                legacyPassword: { [secureStore] key in databaseKeychain.read(key: key) ?? secureStore.read(key: key) },
                credentials: pluginCredentials,
                log: { [applicationLogging] message in
                    applicationLogging?.record(level: "warn", scope: "plugins.migration", message: message, fields: [:])
                }
            )
            // Host services of backend requests: the credentials of
            // protocol 2 and the workspace contexts of protocol 3. Context
            // state lives below each plugin's `${stateDir}` in Application
            // Support, never in the bundle or the package.
            let hostDispatcher = PluginHostServiceDispatcher(contexts: .shared)
            hostDispatcher.register(PluginCredentialHostService(credentials: pluginCredentials))
            let backendDirectories = MacPluginStateDirectories(fileStorage: fileStorage)
            let workspaceHost = PluginWorkspaceHostService(
                contexts: .shared,
                backendStateDirectory: { backendDirectories.backendStateDirectory(pluginID: $0) },
                rootIDSecret: { MacPluginRootIDSecret.load(from: MacPluginRootIDSecret.fileURL(fileStorage: fileStorage)) }
            )
            hostDispatcher.register(workspaceHost)
            hostDispatcher.register(PluginDocumentHostService(contexts: .shared))
            let editorActions = PluginEditorActionHostService(contexts: .shared, decoder: declarativePluginOperations)
            hostDispatcher.register(editorActions)
            hostDispatcher.register(PluginFileHostService(contexts: .shared, metadata: workspaceHost,
                files: MacPluginWorkspaceFileService(
                    searchOperations: RustWorkspaceOperations(core: rustCore),
                    watcherFactory: MacDirectoryWatcherFactory(registry: remoteWorkspaces, transport: remoteTransport),
                    isRemoteWorkspaceRoot: { remoteWorkspaces.resolve($0) != nil }
                )))
            hostDispatcher.register(PluginWindowHostService(contexts: .shared, metadata: workspaceHost,
                                                            fileStorage: fileStorage, platformUI: platformUI))
            let sessions = MacPluginBackendSessions(
                launchResolver: pluginLaunchResolver,
                tools: MacBuildToolResolver(runtime: runtimeService, processRunner: processRunner, fileStorage: fileStorage),
                versionChecker: declarativePluginOperations,
                runtime: runtimeService,
                core: rustCore,
                processRegistry: processRegistry,
                credentials: pluginCredentials,
                prepareState: { [applicationLogging] installation, stateDirectory in
                    if case let .migrated(profiles, passwords) = databaseMigration.prepare(installation: installation, stateDirectory: stateDirectory) {
                        applicationLogging?.record(level: "info", scope: "plugins.migration", message: "database connections moved into the plugin",
                            fields: ["profiles": String(profiles), "passwords": String(passwords)])
                    }
                },
                canStart: { id in
                    guard moduleLaunchMode != .safeMode,
                          let package = pluginStartup.registeredPlugins.first(where: { $0.descriptor.id.rawValue == id }),
                          let module = package.manifest.modules.first(where: {
                              $0.manifest.id == .backendExtension(id) || $0.manifest.id == ModuleID("\(id).ui")
                          })?.manifest else { return false }
                    return (moduleStore.enabledState(for: module.id) ?? (module.defaultState == .enabled))
                        && !moduleStore.isQuarantined(module.id)
                },
                hostDispatcher: hostDispatcher
            )
            sessions.editorActions = editorActions
            sessions.onActivationFailure = { [applicationLogging] pluginID, error in
                applicationLogging?.record(level: "warn", scope: "plugins.backend", message: "backend activation failed",
                    fields: ["plugin": pluginID, "error": error.localizedDescription])
            }
            return sessions
        }
        pluginBackends.register(pluginStartup.registeredPlugins)
        let rustLanguageProviderCatalogSource = RustLanguageProviderCatalogSource(core: rustCore)
        // Installation owns the process-backed language boundary even when a
        // package is disabled, quarantined, or failed to load. Only the active
        // manifests below contribute factories; keeping static ownership here
        // prevents the host from silently restoring its legacy process path.
        let installedLanguageSupports = BundledLanguagePluginCatalog.languageSupports
            + pluginStartup.installedLanguageSupports
        let languageProviderCatalogSource = PluginLanguageProviderCatalogSource(
            base: rustLanguageProviderCatalogSource,
            languageSupports: installedLanguageSupports,
            liveLanguageSupports: { liveSnapshotBox.snapshot.languageSupports }
        )
        let languageProviderCatalogSnapshot = languageProviderCatalogSource.load()
        let languageProviderCatalog = languageProviderCatalogSnapshot.catalog
        let debugProviderCache = DebugProviderCache(
            currentGeneration: { liveSnapshotBox.snapshot.generation },
            providers: languageProviderCatalog.debugProviders,
            reload: { languageProviderCatalogSource.load().catalog.debugProviders }
        )
        // A debug-only declaration adds a debugger to a language another owner
        // serves, so it must not switch the host's own tools for it off.
        let languageOwningSupports = installedLanguageSupports.filter { !$0.isDebugOnly && !$0.isEditorOnly }
        let pluginLanguageIDs = Set(languageOwningSupports.map(\.id))
        // A package may declare, through its host integration, that the host
        // keeps providing a feature of its language. Everything else of an
        // installed language needs the package's own module.
        let hostLanguageCapabilities = Dictionary(
            languageOwningSupports.map { ($0.id, $0.hostCapabilities) },
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
                        workspaceSessionFactory: { descriptor, root in
                            LanguageServerRuntimeSession(providerID: descriptor.launchSource?.languageID ?? "remote",
                                executableURL: root, arguments: [], environment: [:], prepareProcess: { workspace in
                                    try await remotePluginLaunches.prepareLanguage(descriptor, workspaceURL: workspace,
                                        tools: providerTools, versionChecker: declarativePluginOperations)
                                }, core: rustCore, processRegistry: processRegistry, pluginID: descriptor.launchSource?.pluginID)
                        },
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
                            if remoteWorkspaces.contains(workspaceRootURL) { return nil }
                            return try languageServerHostIntegrations.workspaceFingerprint(
                                for: descriptor,
                                workspaceRootURL: workspaceRootURL
                            )
                        },
                        workspaceStateResetter: { descriptor, workspaceRootURL, fingerprint in
                            guard !remoteWorkspaces.contains(workspaceRootURL) else { throw CocoaError(.featureUnsupported) }
                            try languageServerHostIntegrations.resetWorkspaceState(
                                for: descriptor,
                                workspaceRootURL: workspaceRootURL,
                                fingerprint: fingerprint
                            )
                        },
                        workspaceStateCleaner: { descriptor, workspaceRootURL, fingerprint in
                            if remoteWorkspaces.contains(workspaceRootURL) { return 0 }
                            return try languageServerHostIntegrations.pruneWorkspaceState(
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
                        metadataResolver: ProcessRunToolchainMetadataResolver(processRunner: processRunner),
                        environmentResolver: rustCore
                    )
                    let runService = RunService(
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
                    )
                    let buildSystemPlugins = pluginStartup.registeredPlugins.filter { !$0.descriptor.buildSystems.isEmpty }
                    let buildSystems = buildSystemPlugins.isEmpty ? nil : BuildSystemService(
                        planner: RustBuildSystemOperations(core: rustCore),
                        tools: MacBuildToolResolver(
                            runtime: runtimeService,
                            processRunner: processRunner,
                            fileStorage: fileStorage,
                            registry: remoteWorkspaces,
                            remoteFiles: remoteOperations,
                            remoteProcesses: remoteOperations
                        ),
                        optionsStore: MacBuildOptionsStore(store: store),
                        stateLocator: MacRemoteBuildStateLocator(local: MacBuildSystemStateLocator(
                            directories: MacPluginStateDirectories(fileStorage: fileStorage),
                            fileStorage: fileStorage
                        ), registry: remoteWorkspaces, host: remoteOperations, packages: remotePluginPackages),
                        runner: MacRemoteBuildCommandRunner(
                            local: MacBuildCommandRunner(processRegistry: processRegistry),
                            registry: remoteWorkspaces, host: remoteOperations),
                        providers: buildProviderSessions,
                        runLauncher: runService,
                        settings: { pluginSettings.values(forPlugin: $0) },
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
                        run: runService,
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
                                transport: MacHostedPortDebugAdapterTransport(
                                    portResolver: { rootURL in
                                        guard let capability = try await moduleRuntime
                                            .activateCapability(.languageIntelligence)
                                            as? LanguageIntelligenceCapability else {
                                            throw MacHostedPortDebugAdapterTransport.TransportError
                                                .languageIntelligenceUnavailable
                                        }
                                        return try await capability.sessions.startJavaDebugServer(
                                            rootURL: rootURL
                                        )
                                    },
                                    core: rustCore
                                ),
                                core: rustCore,
                                deadlineScheduler: MacDebugOperationDeadlineScheduler()
                            )
                        }
                    ]
                    let adapterSessions = DebugAdapterSessionManager(
                        providersSource: {
                            let languages = debugProviderCache.providers()
                            let qualified = qualifiedDebugAdapters().sorted { $0.key < $1.key }.map {
                                $0.value.provider(languages: languages)
                            }
                            return languages + qualified
                        },
                        makeSession: { descriptor, _ in
                            if let factory = debugFactories[descriptor.id] { return factory() }
                            guard let entry = activeDebugAdapter(descriptor.id) else { return nil }
                            let pluginID = entry.plugin.descriptor.id.rawValue
                            let session = CoreDebugAdapterProtocolSession(
                                adapterID: entry.adapter.adapterID,
                                consoleCommands: entry.adapter.consoleCommands,
                                consoleCommandPrefix: entry.adapter.consoleCommandPrefix,
                                disabledCapabilities: entry.adapter.disabledCapabilities,
                                transport: MacPluginDebugAdapterTransport(
                                    adapterID: entry.adapter.id,
                                    resolve: { rootURL in
                                        try pluginLaunchResolver.resolveDebugAdapter(
                                            pluginID: pluginID,
                                            adapterID: entry.adapter.id,
                                            manifest: entry.plugin.descriptor.normalizedManifest,
                                            packageURL: entry.plugin.packageURL,
                                            workspaceRootURL: rootURL
                                        )
                                    },
                                    makeProcess: { MacRawProcessSession() },
                                    core: rustCore,
                                    findCommand: { commands in
                                        commands.lazy.compactMap { command in
                                            runtimeService.executableCandidates(command)
                                                .first { $0.source != .project }?.executableURL
                                        }.first
                                    },
                                    startHostedPort: { languageID, command, rootURL in
                                        guard let capability = try await moduleRuntime
                                            .activateCapability(.languageIntelligence)
                                            as? LanguageIntelligenceCapability else {
                                            throw MacHostedPortDebugAdapterTransport.TransportError
                                                .languageIntelligenceUnavailable
                                        }
                                        try await Self.prepareHostedDebugAdapterLanguageServer(
                                            languageID: languageID, pluginID: pluginID,
                                            supports: installedLanguageSupports,
                                            runtime: moduleRuntime, sessions: capability.sessions,
                                            prepareTools: { descriptor in
                                                if capability.tools.needsCandidateValidation(for: descriptor) {
                                                    await capability.tools.refreshCandidates(for: descriptor)
                                                }
                                            }
                                        )
                                        return try await capability.sessions.startHostedDebugAdapter(
                                            languageID: languageID,
                                            pluginID: pluginID,
                                            command: command,
                                            rootURL: rootURL
                                        )
                                    }
                                ),
                                core: rustCore,
                                deadlineScheduler: MacDebugOperationDeadlineScheduler()
                            )
                            // Remembered so withdrawing this plugin ends this session
                            // and no other plugin's session for the same language.
                            debugAdapterSessionsBox.record(session, pluginID: pluginID)
                            return session
                        }
                    )
                    adapterSessions.makeEndpointSession = { descriptor, endpoint, _ in
                        let entry = activeDebugAdapter(descriptor.id)
                        guard descriptor.id == "java" || entry != nil else { return nil }
                        let session = CoreDebugAdapterProtocolSession(
                            adapterID: entry?.adapter.adapterID ?? "java",
                            consoleCommands: entry?.adapter.consoleCommands ?? [],
                            consoleCommandPrefix: entry?.adapter.consoleCommandPrefix,
                            disabledCapabilities: entry?.adapter.disabledCapabilities ?? [],
                            transport: try MacExternalDebugAdapterTransport.make(
                                endpoint: endpoint,
                                validate: { endpoint in
                                    do {
                                        return try rustCore.executeResult(
                                            command: "debug.validateAdapterEndpoint", payload: endpoint
                                        ).get()
                                    } catch let error as RustCoreBridge.CoreCallError where error.code == "invalid_request" {
                                        throw MacTCPDebugAdapterTransport.TransportError.invalidEndpoint
                                    }
                                },
                                core: rustCore
                            ),
                            core: rustCore,
                            deadlineScheduler: MacDebugOperationDeadlineScheduler(),
                            // The session clock starts before the socket exists, so Core sizes
                            // it to outlast the transport's connect budget and still leave a
                            // full DAP handshake window; the transport deadline then reports a
                            // slow connect as itself, not as a failed `initialize`.
                            initializationTimeoutMilliseconds:
                                try rustCore.debugTransportPolicy().initializationMilliseconds
                        )
                        if let entry {
                            debugAdapterSessionsBox.record(session, pluginID: entry.plugin.descriptor.id.rawValue)
                        }
                        return session
                    }
                    debugAdapterSessionsBox.manager = adapterSessions
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
        let workspaceOperations: any WorkspaceOperations = RemoteRoutingWorkspaceOperations(
            local: providedWorkspaceOperations ?? defaultWorkspaceOperations,
            registry: remoteWorkspaces,
            transport: remoteTransport
        )
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
            backends: pluginBackends,
            prompt: MacPluginWebConsentPrompt.confirm,
            chooseFile: MacPluginWebFileDialog.choose
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
            invalidateWebPages: { id in
                pluginWebPageLifecycle.disable(id.rawValue)
                pluginBackends.disable(id.rawValue)
            },
            enableWebPages: { id in
                pluginBackends.enable(id.rawValue)
                pluginWebPageLifecycle.enable(id.rawValue)
            },
            beforePackageReplacement: { id in
                pluginWebPageLifecycle.packageWillChange(id.rawValue)
                pluginBackends.packageWillChange(id.rawValue)
                // The running provider still executes the old files; the
                // build systems' plugin list is a startup snapshot and does
                // not see the replacement.
                buildProviderSessions.stopProviders(ofPlugin: id.rawValue)
                vcsProviderSessions.stopProviders(ofPlugin: id.rawValue)
                livePlugins.willReplacePackage(of: id)
            },
            reviewPrograms: { [pluginMarketplaceEvaluator] manifest, id, version in
                try pluginMarketplaceEvaluator.installReview(
                    manifest: manifest,
                    expectedID: id.rawValue,
                    expectedVersion: version.description,
                    approvedPrograms: nil
                ).programs
            },
            expandWorkspaceConfiguration: { manifest, languageID, global, project in
                try declarativePluginOperations.workspaceConfiguration(
                    manifest: manifest, languageID: languageID, settings: global, projectSettings: project
                )
            },
            lookUpDebugExecutable: { plugin, adapterID, workspaceRootURL, targetPath in
                // The page only echoes what a launch would find; a plan Core
                // cannot make shows nothing here and fails with its reason at launch.
                try? debugExecutableResolver.lookup(
                    plugin: plugin,
                    adapterID: adapterID,
                    workspaceRootURL: workspaceRootURL,
                    targetPath: targetPath
                )
            },
            livePlugins: livePlugins
        )
        let pluginMarketplace = MacPluginMarketplaceService(
            evaluator: pluginMarketplaceEvaluator,
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
            validatePluginNativeUI: declarativePluginOperations.validateNativeNodes,
            languageProviderCatalogSource: languageProviderCatalogSource,
            workspaceLanguageServerPreferences: workspaceLanguageServerPreferences,
            languageProviderCatalogSnapshot: languageProviderCatalogSnapshot,
            debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver(
                javaTestLaunchResolver: rustCore,
                providerLaunch: { source, preparation, workspaceURL, title in
                    try MacBuildDebugLaunchResolver(planner: declarativePluginOperations,
                        entry: { qualifiedDebugAdapters()[$0] }, generation: { liveSnapshotBox.snapshot.generation })
                        .resolve(source: source, preparation: preparation, workspaceURL: workspaceURL, title: title)
                },
                javaExecutablePath: { [runtimeService] runtime in
                    runtimeService.javaExecutableURL(forDebugging: runtime)?.path
                },
                pluginLaunch: { languageID, documentURL, workspaceURL in
                    guard let entry = activeDebugAdapter(languageID) else { return nil }
                    let targetPath = documentURL.standardizedFileURL.path
                    // The program the adapter launches is the host's to find;
                    // a plugin that declares none gets no `executable` fact.
                    let executable = try debugExecutableResolver.executableForLaunch(
                        plugin: entry.plugin,
                        adapter: entry.adapter,
                        workspaceRootURL: workspaceURL,
                        targetPath: targetPath
                    )
                    // Prepared against the registry's current generation, which
                    // is the one Core compares the start with.
                    let generation = liveSnapshotBox.snapshot.generation
                    let arguments = try declarativePluginOperations.debugStartArguments(
                        manifest: entry.plugin.descriptor.normalizedManifest,
                        adapterID: entry.adapter.id,
                        request: DeclarativeDebugStartRequest(
                            request: .launch,
                            targetKind: "file",
                            path: targetPath,
                            workingDirectory: workspaceURL.standardizedFileURL.path,
                            executable: executable,
                            registrationGeneration: generation,
                            currentRegistrationGeneration: generation
                        )
                    )
                    return DebugLaunchConfiguration(
                        name: documentURL.lastPathComponent,
                        request: .launch,
                        arguments: arguments,
                        adapterProviderID: entry.providerID
                    )
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
            diagnosticsExportService: diagnosticsExportService,
            credentialResolver: credentialResolver,
            agentManagement: RustAgentManagementService(core: rustCore, accountDirectory: { agentID in
                await MainActor.run { settings.preferredAgentAccountDirectory(for: agentID) }
            }),
            agentInstructions: RustAgentInstructionsService(core: rustCore,
                sharedDirectory: fileStorage.applicationSupportDirectory().appendingPathComponent("Lithe/AgentInstructions", isDirectory: true)),
            agentHooks: RustAgentHooksService(core: rustCore,
                directory: fileStorage.applicationSupportDirectory().appendingPathComponent("Lithe/AgentHooks", isDirectory: true)),
            agentAccountSignIn: MacAgentAccountSignIn(runner: processRunner),
            agentProviderConfigurationParser: MacAgentProviderConfigurationParser(core: rustCore),
            aiConfigurationSources: aiConfigurationSources,
            recentProjectsStore: RecentProjectsStore(store: store, excludes: { remoteWorkspaces.contains($0) }),
            recentProjectBranchReader: MacRecentProjectBranchReader(storage: fileStorage),
            workspaceSessionStore: WorkspaceSessionStore(store: store),
            directoryMarkStore: directoryMarkStore,
            workbenchLayoutStore: WorkbenchLayoutStore(store: store),
            workbenchBackgroundPlatform: MacWorkbenchBackgroundPlatform(store: store),
            directoryWatcherFactory: MacDirectoryWatcherFactory(registry: remoteWorkspaces, transport: remoteTransport),
            platformUI: platformUI,
            shortcutDetectorFactory: MacShortcutDetectorFactory(),
            debugPerformanceSampler: MacDebugPerformanceSampler(processRegistry: processRegistry),
            testJVMPerformance: MacTestJVMPerformance(processRegistry: processRegistry)
        )
        services.ideCapabilityRegistry = ideCapabilityRegistry
        services.pluginRegistrationChanges = livePlugins.changes
        // Static editor resources follow their own enablement; ordinary tool
        // actions register at runtime in the shared backend's host services.
        let editorLanguageModuleChanges = PassthroughSubject<Void, Never>()
        MacPluginEditorLanguages.observeModuleChanges(on: moduleRuntime, changed: {
            editorLanguageModuleChanges.send()
        }) { runtime in
            for package in pluginStartup.registeredPlugins where package.descriptor.declaresBackend && package.descriptor.ui == nil {
                let id = package.descriptor.id.rawValue
                if let state = try? runtime.snapshot(for: .backendExtension(id)),
                   state.state != .disabled, !state.isQuarantined, !state.isSuppressedBySafeMode {
                    pluginBackends.enable(id)
                } else { pluginBackends.disable(id) }
            }
        }
        services.pluginEditorActions = pluginBackends.editorActions
        services.pluginEditorLanguages = MacPluginEditorLanguages(
            launchRegistered: pluginStartup.registeredPlugins,
            isModuleUsable: { [weak moduleRuntime] id in
                guard let snapshot = try? moduleRuntime?.snapshot(for: id) else { return false }
                return snapshot.state != .disabled && !snapshot.isQuarantined && !snapshot.isSuppressedBySafeMode
            },
            livePackages: { liveSnapshotBox.snapshot.activePackages },
            decoder: declarativePluginOperations,
            triggers: [livePlugins.changes, editorLanguageModuleChanges.eraseToAnyPublisher()],
            log: { message, fields in
                NSLog("Lithe %@ %@", message, fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            }
        )
        services.ideHostTransport = MacIdeHostTransport(core: rustCore, storage: fileStorage)
        services.proxyPasswordStore = proxyPasswordStore
        services.proxyConnectionChecker = proxyConnectionChecker
        services.mcpConfigurationStore = MacAgentMcpConfigurationStore(
            core: rustCore, storage: fileStorage
        )
        services.mcpRegistry = MacMcpRegistry(core: rustCore)
        if let configuration = services.mcpConfigurationStore {
            services.mcpTools = MacMcpTools(core: rustCore, store: configuration, ledger: services.store, storage: fileStorage)
        }
        services.connectBuildProviderLanguageSessions = { sessions in
            buildProviderSessions.languageSessions = sessions
        }
        let vcsProviderPlugins = pluginStartup.registeredPlugins.filter { !$0.descriptor.vcsProviders.isEmpty }
        if !vcsProviderPlugins.isEmpty {
            services.vcsProviders = VcsProvidersFeatureModel(
                planner: RustVcsOperations(core: rustCore),
                providers: vcsProviderSessions,
                mappingStore: MacVcsRootMappingStore(store: store),
                readFile: { url in try? fileStorage.readData(from: url, options: .mappedIfSafe) },
                fileExists: { url in fileStorage.fileExists(at: url) },
                metadataWatcherFactory: MacDirectoryWatcherFactory(registry: remoteWorkspaces, transport: remoteTransport),
                sources: {
                    // Enablement is read on every detection, so turning a
                    // plugin off takes its roots away at once.
                    vcsProviderPlugins.compactMap { plugin -> VcsProviderPluginSource? in
                        let id = plugin.descriptor.id.rawValue
                        guard let snapshot = try? moduleRuntime.snapshot(for: .vcsProvidersExtension(id)),
                              snapshot.state != .disabled,
                              !snapshot.isQuarantined,
                              !snapshot.isSuppressedBySafeMode else { return nil }
                        return VcsProviderPluginSource(
                            pluginID: id,
                            manifest: plugin.descriptor.normalizedManifest,
                            packageURL: plugin.packageURL,
                            providers: plugin.descriptor.vcsProviders
                        )
                    }
                }
            )
        }
        services.pluginWorkspaceContexts = PluginWorkspaceContexts.shared
        services.pluginBackendActivation = pluginBackends
        services.processExitCoordinator = ProcessExitCoordinator(
            core: RustProcessLifecycleDecider(core: rustCore),
            presenter: MacProcessExitConfirmationPresenter.shared
        )
        // Remote Development window. Passwords and key passphrases use their
        // own keychain service so they never mix with Git or database secrets.
        services.remoteConnections = RemoteConnectionServices(
            store: RemoteConnectionStore(
                store: store,
                secureStore: MacKeychainSecureStore(service: fileStorage.identity.keychainService("remote"))
            ),
            prober: remoteOperations,
            sessions: remoteOperations,
            locator: MacRemoteHostLocator(),
            workspaces: remoteWorkspaces,
            prepareWorkspaceRoot: { connectionID, remotePath in
                try MacRemoteWorkspaceRoots.prepare(
                    in: fileStorage.applicationSupportDirectory(), connection: connectionID, remotePath: remotePath
                )
            },
            servers: MacRemoteServerBundleLocator.locate()
        )
        // New Project window. Plugin packages are read-only; projects are
        // written into a staging directory inside the folder the user chose.
        services.projectGeneration = ProjectGenerationService(
            planner: RustProjectGeneratorOperations(core: rustCore),
            platform: MacProjectGenerationPlatform(
                runtime: runtimeService,
                runner: MacBuildCommandRunner(processRegistry: processRegistry)
            ),
            initializeGitRepository: { root in
                switch gitOperations.initializeRepository(at: root) {
                case .success: nil
                case .failure(let failure): failure.message
                }
            },
            recordJavaHome: { root, home in
                await runtimeService.presetJavaHome(home, for: root)
            }
        )
        let installedPlugins = pluginStartup.registeredPlugins
        services.loginShellEnvironmentInspector = MacLoginShellEnvironment.shared
        services.toolchainSettingsLoader = MacToolchainSettingsLoader(
            sources: { [pluginManager] in
                let enabled = Set(pluginManager.snapshots.filter(\.isEnabled).map(\.id))
                return installedPlugins.map { plugin in
                    ToolchainSettingsPluginSource(
                        pluginID: plugin.descriptor.id.rawValue,
                        name: plugin.manifest.displayName,
                        manifest: plugin.descriptor.normalizedManifest,
                        isEnabled: enabled.contains(plugin.descriptor.id)
                    )
                }
            },
            directories: { [weak services] _ in services?.toolchainSettingsDirectories?() ?? [] },
            isRemoteWorkspace: { remoteWorkspaces.contains($0) }
        )
        services.projectGeneratorSources = { [pluginManager] in
            // Enablement is read on every call, so a plugin enabled from the
            // window shows its entries and satisfies requirements at once.
            let enabled = Set(pluginManager.snapshots.filter(\.isEnabled).map(\.id))
            return installedPlugins.map { plugin in
                ProjectGeneratorPluginSource(
                    pluginID: plugin.descriptor.id,
                    manifest: plugin.descriptor.normalizedManifest,
                    packageURL: plugin.packageURL,
                    isEnabled: enabled.contains(plugin.descriptor.id)
                )
            }
        }
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

    /// Debugging can start from a saved configuration before any source file
    /// has activated the plugin's language-server module.
    static func prepareHostedDebugAdapterLanguageServer(
        languageID: String,
        pluginID: String,
        supports: [LanguageSupportDeclaration],
        runtime: ModuleRuntime,
        sessions: LanguageToolingSessionManager,
        prepareTools: @MainActor (LanguageProviderDescriptor) async -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let support = supports.first(where: { $0.id == languageID && !$0.isDebugOnly && !$0.isEditorOnly }),
              let moduleID = support.languageServerModuleID,
              let snapshot = try? runtime.snapshot(for: moduleID),
              snapshot.state != .disabled, !snapshot.isQuarantined, !snapshot.isSuppressedBySafeMode else {
            throw LanguageToolingSessionError.languageServerNotOwnedByPlugin(languageID: languageID)
        }
        let provider = try await runtime.activateCapability(.languageServerExtension(languageID))
            as? any LanguageServerExtensionProviding
        try Task.checkCancellation()
        guard let provider, provider.configuration.launchSource?.pluginID == pluginID,
              sessions.registerLanguageServerExtension(provider, support: support),
              let descriptor = sessions.languageServerExtensionDescriptor(languageID: languageID) else {
            throw LanguageToolingSessionError.languageServerNotOwnedByPlugin(languageID: languageID)
        }
        await prepareTools(descriptor)
        try Task.checkCancellation()
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
            // The build-systems, VCS-providers, and project-generators
            // modules also carry the enabled state; the host reads it before
            // handing the plugin to Rust Core or the New Project window.
            let workbench = descriptor.pluginManifest.modules.filter {
                !$0.contributions.isEmpty
                    || $0.manifest.id == .buildSystemsExtension(descriptor.id.rawValue)
                    || $0.manifest.id == .vcsProvidersExtension(descriptor.id.rawValue)
                    || $0.manifest.id == .debugAdaptersExtension(descriptor.id.rawValue)
                    || $0.manifest.id == .grammarsExtension(descriptor.id.rawValue)
                    || $0.manifest.id == .backendExtension(descriptor.id.rawValue)
                    || $0.manifest.id == .projectGeneratorsExtension(descriptor.id.rawValue)
            }.map { declaration in
                ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
                    DeclarativeWorkbenchModule(declaration: declaration)
                }
            }
            return servers + executions + workbench
        }
    }
}

/// Reaches the debug session manager from the live plugin registry, which is
/// created before the debug module's graph exists, and remembers which plugin
/// each plugin-provided session was built from.
@MainActor
private final class DebugAdapterSessionsBox {
    weak var manager: DebugAdapterSessionManager?
    private struct Owner {
        weak var session: AnyObject?
        let pluginID: String
    }
    private var owners: [Owner] = []

    /// Called by the session factory for every session a plugin's adapter backs.
    func record(_ session: any DebugAdapterSession, pluginID: String) {
        owners.removeAll { $0.session == nil }
        owners.append(Owner(session: session, pluginID: pluginID))
    }

    /// Sessions run from the files of the package they started with, so they
    /// end when the package is replaced, removed or turned off. Only that
    /// plugin's own sessions end: another plugin or the host's adapter may be
    /// debugging the same language.
    func stopSessions(ofPlugin pluginID: String) {
        guard let manager else { return }
        manager.stopSessions { session in
            owners.contains { $0.session === session && $0.pluginID == pluginID }
        }
    }
}

/// The debug providers for one registry generation, so a lookup per file does
/// not rebuild the language catalog until a live plugin changed.
@MainActor
private final class DebugProviderCache {
    private let currentGeneration: () -> Int
    private let reload: () -> [DebugProviderDescriptor]
    private var generation: Int
    private var cached: [DebugProviderDescriptor]

    init(
        currentGeneration: @escaping () -> Int,
        providers: [DebugProviderDescriptor],
        reload: @escaping () -> [DebugProviderDescriptor]
    ) {
        self.currentGeneration = currentGeneration
        self.reload = reload
        generation = currentGeneration()
        cached = providers
    }

    func providers() -> [DebugProviderDescriptor] {
        let latest = currentGeneration()
        if latest != generation {
            generation = latest
            cached = reload()
        }
        return cached
    }
}
