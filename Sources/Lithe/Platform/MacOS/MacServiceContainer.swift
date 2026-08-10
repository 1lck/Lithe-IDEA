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
            toolchainSource: runConfigurationStore,
            toolDiscovery: MacRuntimeToolDiscovery()
        )
        let languageProviderCatalog = LanguageProviderCatalog.standard
        // Build the catalog once so every standard runtime consumes the
        // language-pack launch metadata instead of maintaining a second map.
        let languagePackDefinitions = LanguagePackRegistry.standard(
            catalog: languageProviderCatalog
        )
        let languageService = JavaLanguageService(
            runtimeService: runtimeService,
            process: MacRawProcessSession(),
            archiveReader: MacArchiveEntryReader(processRunner: processRunner),
            fileStorage: fileStorage,
            javaMavenOperations: javaMavenOperations
        )
        let javaDebugLaunch = languagePackDefinitions.pack(id: "java")?.debugAdapterLaunch
        let javaRuntime = JavaLanguageProviderRuntime(
            service: languageService,
            catalog: languageProviderCatalog,
            debugAdapterAvailability: {
                guard let projectURL = runtimeService.projectURL else { return false }
                let locator = MacJavaDebugAdapterLocator(
                    environment: runtimeService.processEnvironment(),
                    launchDefinition: javaDebugLaunch
                )
                return locator.resolve(
                    rootURL: projectURL,
                    javaExecutableURL: runtimeService.configuredJavaExecutableURL()
                ) != nil
            },
            debugAdapterUnavailableMessage: {
                MacJavaDebugAdapterLocator(
                    environment: runtimeService.processEnvironment(),
                    launchDefinition: javaDebugLaunch
                ).unavailableMessage
            },
            debugAdapterFactory: { rootURL in
                let locator = MacJavaDebugAdapterLocator(
                    environment: runtimeService.environment(for: .java),
                    launchDefinition: javaDebugLaunch
                )
                guard let launch = locator.resolve(
                    rootURL: rootURL,
                    javaExecutableURL: runtimeService.javaExecutableURL()
                ) else { return nil }
                return DebugAdapterProtocolSession(
                    adapterID: "java",
                    executableURL: launch.executableURL,
                    arguments: launch.arguments,
                    environment: launch.environment,
                    process: MacRawProcessSession()
                )
            }
        )
        let languageToolingRuntimes: [any LanguageProviderRuntime] = [
            javaRuntime
        ] + StdioLanguageProviderRuntime.standard(
            packs: languagePackDefinitions.packs,
            runtimeService: runtimeService,
            processFactory: { MacRawProcessSession() },
            debugSessionFactories: [
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
        )
        let languagePackRegistry = LanguagePackRegistry.standard(
            catalog: languageProviderCatalog,
            runtimes: languageToolingRuntimes
        )
        let runToolchainRegistry = languagePackRegistry.toolchainRegistry
        let languageToolingSessions = LanguageToolingSessionManager(
            registry: languagePackRegistry
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
        let javaImplementationMarkerService = JavaImplementationMarkerService(
            languageService: languageService
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
            languageProviderCatalog: languagePackRegistry.catalog,
            languagePacks: languagePackRegistry,
            runToolchainRegistry: runToolchainRegistry,
            languageToolingSessions: languageToolingSessions,
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
            javaLanguageService: languageService,
            javaImplementationMarkerService: javaImplementationMarkerService,
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
