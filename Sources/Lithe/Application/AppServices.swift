import Foundation

protocol DirectoryWatcherFactory {
    func make(
        root: URL,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable ([String]) -> Void
    ) -> any DirectoryChangeSource
}

/// Platform-neutral service graph consumed by application orchestration.
/// Platform composition roots construct this graph with their own adapters.
@MainActor
final class AppServices {
    let store: any KeyValueStore
    let fileStorage: any FileStorage
    let workspaceScanner: WorkspaceScanner
    let fileOperations: any WorkspaceFileOperations
    let projectRuntimeService: ProjectRuntimeService
    let javaLanguageService: JavaLanguageService
    let javaImplementationMarkerService: JavaImplementationMarkerService
    let mavenService: MavenService
    let javaRunService: JavaRunService
    let javaDebugService: JavaDebugService
    let gitService: GitService
    let searchIndex: WorkspaceSearchIndex
    let recentProjectsStore: RecentProjectsStore
    let workspaceSessionStore: WorkspaceSessionStore
    let workbenchLayoutStore: WorkbenchLayoutStore
    let terminalFactory: () -> any TerminalTransport
    let directoryWatcherFactory: any DirectoryWatcherFactory
    let platformUI: any PlatformUI
    let shortcutDetectorFactory: any ShortcutDetectorFactory

    init(
        store: any KeyValueStore,
        fileStorage: any FileStorage,
        workspaceScanner: WorkspaceScanner,
        fileOperations: any WorkspaceFileOperations,
        projectRuntimeService: ProjectRuntimeService,
        javaLanguageService: JavaLanguageService,
        javaImplementationMarkerService: JavaImplementationMarkerService,
        mavenService: MavenService,
        javaRunService: JavaRunService,
        javaDebugService: JavaDebugService,
        gitService: GitService,
        searchIndex: WorkspaceSearchIndex,
        recentProjectsStore: RecentProjectsStore,
        workspaceSessionStore: WorkspaceSessionStore,
        workbenchLayoutStore: WorkbenchLayoutStore,
        terminalFactory: @escaping () -> any TerminalTransport,
        directoryWatcherFactory: any DirectoryWatcherFactory,
        platformUI: any PlatformUI,
        shortcutDetectorFactory: any ShortcutDetectorFactory
    ) {
        self.store = store
        self.fileStorage = fileStorage
        self.workspaceScanner = workspaceScanner
        self.fileOperations = fileOperations
        self.projectRuntimeService = projectRuntimeService
        self.javaLanguageService = javaLanguageService
        self.javaImplementationMarkerService = javaImplementationMarkerService
        self.mavenService = mavenService
        self.javaRunService = javaRunService
        self.javaDebugService = javaDebugService
        self.gitService = gitService
        self.searchIndex = searchIndex
        self.recentProjectsStore = recentProjectsStore
        self.workspaceSessionStore = workspaceSessionStore
        self.workbenchLayoutStore = workbenchLayoutStore
        self.terminalFactory = terminalFactory
        self.directoryWatcherFactory = directoryWatcherFactory
        self.platformUI = platformUI
        self.shortcutDetectorFactory = shortcutDetectorFactory
    }
}
