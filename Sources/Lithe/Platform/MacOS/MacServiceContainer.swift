import Foundation

private struct MacDirectoryWatcherFactory: DirectoryWatcherFactory {
    func make(
        root: URL,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable ([String]) -> Void
    ) -> any DirectoryChangeSource {
        MacDirectoryWatcher(
            root: root,
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

    init(store: any KeyValueStore) {
        let rustCore = RustCoreBridge()
        let javaMavenOperations = RustJavaMavenOperations(core: rustCore)
        let fileStorage = MacFileStorage()
        runConfigurationStore = MacRunConfigurationStore(
            core: rustCore,
            storage: fileStorage,
            preferences: store
        )
        let fileOperations = MacWorkspaceFileOperations()
        let processRunner = MacProcessRunner()
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: store,
            toolDiscovery: MacRuntimeToolDiscovery()
        )
        let languageProviderCatalogSource = RustLanguageProviderCatalogSource(core: rustCore)
        let languageProviderCatalogSnapshot = languageProviderCatalogSource.load()
        let languageProviderCatalog = languageProviderCatalogSnapshot.catalog
        let languageServerTools = LanguageServerToolService(
            runtimeService: runtimeService,
            processRunner: processRunner,
            store: store
        )
        // Build the catalog once so every standard runtime consumes the
        // language-pack launch metadata instead of maintaining a second map.
        let languagePackDefinitions = LanguagePackRegistry.standard(
            catalog: languageProviderCatalog
        )
        Task {
            for descriptor in languageProviderCatalog.descriptors where
                descriptor.capabilities.contains(.languageServer) {
                await languageServerTools.refreshCandidates(for: descriptor)
            }
        }
        let debugSessionFactories: [String: () -> (any DebugAdapterSession)?] = [
            "go": {
                guard let dlv = runtimeService.executableOnPath("dlv") else { return nil }
                return DebugAdapterProtocolSession(
                    adapterID: "go",
                    transport: MacDlvDebugAdapterTransport(
                        executableURL: dlv,
                        environment: runtimeService.processEnvironment(),
                        process: MacRawProcessSession()
                    )
                )
            },
            "node": {
                guard let node = runtimeService.executableOnPath("node") else { return nil }
                let environment = runtimeService.processEnvironment()
                let locator = MacJavaScriptDebugAdapterLocator(
                    environment: environment,
                    executableOnPath: { runtimeService.executableOnPath($0) }
                )
                return DebugAdapterProtocolSession(
                    adapterID: "pwa-node",
                    transport: MacNodeDebugAdapterTransport(
                        nodeExecutableURL: node,
                        locator: locator,
                        process: MacRawProcessSession()
                    )
                )
            }
        ]
        let debugLaunches = Dictionary(
            uniqueKeysWithValues: languagePackDefinitions.packs.compactMap { pack in
                pack.debugAdapterLaunch.map { (pack.descriptor.id, $0) }
            }
        )
        let languageToolingRuntimeFactory = StdioLanguageProviderRuntimeFactory(
            runtimeService: runtimeService,
            processFactory: { MacRawProcessSession() },
            languageServerCore: rustCore,
            languageServerExecutableResolver: { descriptor in
                languageServerTools.executableURL(for: descriptor)
            },
            // JDT LS runs on a JDK the Rust runtime cannot discover for itself.
            languageServerRuntimeResolver: { descriptor in
                descriptor.id == "java" ? runtimeService.activeServiceJavaExecutableURL() : nil
            },
            languageServerCacheDirectory: fileStorage
                .cacheDirectory()
                .appendingPathComponent("Lithe/language-servers", isDirectory: true),
            debugLaunches: debugLaunches,
            debugSessionFactories: debugSessionFactories
        )
        let languageToolingRuntimes: [any LanguageProviderRuntime] = languagePackDefinitions.packs
            .compactMap { languageToolingRuntimeFactory.makeRuntime(for: $0.descriptor) }
        let languagePackRegistry = LanguagePackRegistry.standard(
            catalog: languageProviderCatalog,
            runtimes: languageToolingRuntimes
        )
        let runToolchainRegistry = languagePackRegistry.toolchainRegistry
        let languageToolingSessions = LanguageToolingSessionManager(
            catalog: languagePackRegistry.catalog,
            runtimes: languagePackRegistry.toolingRuntimes,
            runtimeFactory: languageToolingRuntimeFactory,
            core: rustCore
        )
        let testExecutableResolver = RunExecutableResolver(
            runtimeService: runtimeService,
            toolchainRegistry: runToolchainRegistry,
            metadataResolver: ProcessRunToolchainMetadataResolver(processRunner: processRunner)
        )
        let languageTestService = LanguageTestService(
            registry: languagePackRegistry,
            executableResolver: testExecutableResolver,
            processFactory: { MacStreamingProcess() }
        )

        let mavenService = MavenService(
            runtimeService: runtimeService,
            process: MacStreamingProcess(),
            javaMavenOperations: javaMavenOperations
        )
        let runService = RunService(
            runtimeService: runtimeService,
            process: MacStreamingProcess(),
            processFactory: { MacStreamingProcess() },
            fileStorage: fileStorage,
            preferences: store,
            javaMavenOperations: javaMavenOperations,
            runConfigurationOperations: runConfigurationStore,
            executableResolver: RunExecutableResolver(
                runtimeService: runtimeService,
                toolchainRegistry: runToolchainRegistry,
                metadataResolver: ProcessRunToolchainMetadataResolver(processRunner: processRunner)
            ),
            languagePackRegistry: languagePackRegistry
        )
        let javaDebugService = JavaDebugService(
            runtimeService: runtimeService,
            processFactory: { MacStreamingProcess() },
            fileStorage: fileStorage,
            javaMavenOperations: javaMavenOperations,
            runConfigurationOperations: runConfigurationStore
        )
        let gitOperations = RustGitOperations(core: rustCore)
        let workspaceOperations = RustWorkspaceOperations(core: rustCore)
        let localHistoryOperations = RustLocalHistoryOperations(core: rustCore)
        let markdownRenderer = RustMarkdownRendering(core: rustCore)
        let markdownImageImporter = MarkdownImageImportService(storage: fileStorage)
        let gitService = GitService(operations: gitOperations)
        let shelveService = ShelveService(storage: fileStorage)
        let secureStore = MacLocalSecretStore()
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
        let commitMessageGenerator = CommitMessageGenerationService(
            transport: MacURLSessionTransport(),
            credentialResolver: credentialResolver
        )
        services = AppServices(
            languageProviderCatalogSource: languageProviderCatalogSource,
            languageProviderCatalogSnapshot: languageProviderCatalogSnapshot,
            languagePacks: languagePackRegistry,
            runToolchainRegistry: runToolchainRegistry,
            languageToolingSessions: languageToolingSessions,
            languageServerTools: languageServerTools,
            languageTestService: languageTestService,
            workspaceOperations: workspaceOperations,
            localHistoryOperations: localHistoryOperations,
            javaMavenOperations: javaMavenOperations,
            markdownRenderer: markdownRenderer,
            markdownImageImporter: markdownImageImporter,
            store: store,
            fileStorage: fileStorage,
            fileOperations: fileOperations,
            projectRuntimeService: runtimeService,
            mavenService: mavenService,
            runService: runService,
            javaDebugService: javaDebugService,
            gitService: gitService,
            shelveService: shelveService,
            commitMessageGenerator: commitMessageGenerator,
            secureStore: secureStore,
            credentialResolver: credentialResolver,
            aiConfigurationSources: aiConfigurationSources,
            recentProjectsStore: RecentProjectsStore(store: store),
            workspaceSessionStore: WorkspaceSessionStore(store: store),
            workbenchLayoutStore: WorkbenchLayoutStore(store: store),
            terminalFactory: { MacTerminalTransport() },
            directoryWatcherFactory: MacDirectoryWatcherFactory(),
            platformUI: MacPlatformUI(),
            shortcutDetectorFactory: MacShortcutDetectorFactory()
        )
    }
}
