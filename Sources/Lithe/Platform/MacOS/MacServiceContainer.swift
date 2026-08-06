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

    init(store: any KeyValueStore) {
        let rustCore = RustCoreBridge()
        let javaMavenOperations = RustJavaMavenOperations(core: rustCore)
        let fileStorage = MacFileStorage()
        let fileOperations = MacWorkspaceFileOperations()
        let processRunner = MacProcessRunner()
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: store
        )
        let languageService = JavaLanguageService(
            runtimeService: runtimeService,
            process: MacRawProcessSession(),
            archiveReader: MacArchiveEntryReader(processRunner: processRunner),
            fileStorage: fileStorage,
            javaMavenOperations: javaMavenOperations
        )

        let mavenService = MavenService(
            runtimeService: runtimeService,
            process: MacStreamingProcess(),
            javaMavenOperations: javaMavenOperations
        )
        let javaRunService = JavaRunService(
            runtimeService: runtimeService,
            process: MacStreamingProcess(),
            processFactory: { MacStreamingProcess() },
            fileStorage: fileStorage,
            preferences: store,
            javaMavenOperations: javaMavenOperations
        )
        let javaDebugService = JavaDebugService(
            runtimeService: runtimeService,
            processFactory: { MacStreamingProcess() },
            fileStorage: fileStorage,
            javaMavenOperations: javaMavenOperations
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
            javaRunService: javaRunService,
            javaDebugService: javaDebugService,
            gitService: gitService,
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
