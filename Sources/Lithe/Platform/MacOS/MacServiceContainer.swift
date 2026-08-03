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
            fileStorage: fileStorage
        )

        let workspaceScanner = WorkspaceScanner(fileSystem: MacWorkspaceFileSystem())
        let mavenService = MavenService(
            runtimeService: runtimeService,
            process: MacStreamingProcess(),
            projectScanner: MavenProjectScanner(storage: fileStorage)
        )
        let javaRunService = JavaRunService(
            runtimeService: runtimeService,
            process: MacStreamingProcess(),
            processFactory: { MacStreamingProcess() },
            fileStorage: fileStorage,
            preferences: store
        )
        let javaDebugService = JavaDebugService(
            runtimeService: runtimeService,
            processFactory: { MacStreamingProcess() },
            fileStorage: fileStorage
        )
        let javaImplementationMarkerService = JavaImplementationMarkerService(
            languageService: languageService
        )
        let gitService = GitService(
            commandRunner: MacGitCommandRunner(processRunner: processRunner),
            fileOperations: fileOperations
        )
        services = AppServices(
            rustCore: RustCoreBridge(),
            store: store,
            fileStorage: fileStorage,
            workspaceScanner: workspaceScanner,
            fileOperations: fileOperations,
            projectRuntimeService: runtimeService,
            javaLanguageService: languageService,
            javaImplementationMarkerService: javaImplementationMarkerService,
            mavenService: mavenService,
            javaRunService: javaRunService,
            javaDebugService: javaDebugService,
            gitService: gitService,
            searchIndex: WorkspaceSearchIndex(storage: fileStorage),
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
