import Foundation
import LitheCoreContracts
import LitheWorkspaceModule
import Testing
@testable import Lithe

@Suite("Workspace session coordinator")
@MainActor
struct WorkspaceSessionCoordinatorTests {
    @Test
    func openingWaitsForOldModuleTeardownBeforeBeginningTheNewFeatureLifetime() async {
        let preparationStarted = TestGate()
        let finishTeardown = TestGate()
        let loaded = TestGate()
        let feature = makeOpeningFeature(loaded: loaded)
        let platform = CoordinatorTestPlatformUI()
        let coordinator = WorkspaceSessionCoordinator(
            recentProjectsStore: RecentProjectsStore(store: CoordinatorTestStore()),
            platformUI: platform, workspaceFeature: feature
        )
        defer { finishTeardown.open(); coordinator.clearSession(); feature.prepareForModuleRelease() }
        let oldRoot = URL(fileURLWithPath: "/in-memory/coordinator-old")
        let newRoot = URL(fileURLWithPath: "/in-memory/coordinator-new")
        feature.beginWorkspace(at: oldRoot, visibilityRules: .default)
        let oldGeneration = feature.workspaceGeneration
        coordinator.configureLifecycle(with: openingHandlers(wait: {
            preparationStarted.open()
            #expect(await finishTeardown.waitUntilOpen())
            // The old module owns the same long-lived UI projection.
            feature.prepareForModuleRelease()
        }))
        coordinator.openWorkspace(at: newRoot)
        let openingGeneration = coordinator.openingGeneration
        #expect(await preparationStarted.waitUntilOpen())
        #expect(coordinator.openingGeneration == openingGeneration)
        #expect(feature.workspaceGeneration == oldGeneration)
        #expect(feature.appliedSnapshot == nil)
        finishTeardown.open()
        #expect(await loaded.waitUntilOpen())
        #expect(feature.rootNode?.url == newRoot)
        #expect(feature.loadErrorMessage == nil)
        #expect(coordinator.openingGeneration == openingGeneration)
    }

    @Test
    func reopeningTheSameRootWhilePreparationIsPendingStartsOnlyTheLatestLifetime() async {
        let preparationStarted = TestGate()
        let finishPreparation = TestGate()
        let loaded = TestGate()
        let feature = makeOpeningFeature(loaded: loaded)
        let platform = CoordinatorTestPlatformUI()
        let coordinator = WorkspaceSessionCoordinator(
            recentProjectsStore: RecentProjectsStore(store: CoordinatorTestStore()),
            platformUI: platform, workspaceFeature: feature
        )
        defer { finishPreparation.open(); coordinator.clearSession(); feature.prepareForModuleRelease() }
        var preparationCount = 0
        var restorations = 0
        var handlers = openingHandlers(wait: {
            preparationCount += 1
            preparationStarted.open()
            _ = await finishPreparation.waitUntilOpen()
        })
        handlers = .init(
            prepareForWorkspaceOpen: handlers.prepareForWorkspaceOpen,
            prepareForWorkspaceClose: handlers.prepareForWorkspaceClose,
            prepareForStandaloneOpen: handlers.prepareForStandaloneOpen,
            finishStandaloneClose: handlers.finishStandaloneClose,
            beginDocumentClose: handlers.beginDocumentClose,
            runServicesCloseConfirmation: handlers.runServicesCloseConfirmation,
            restoreDebugBreakpoints: { _ in restorations += 1 },
            visibilityRules: handlers.visibilityRules,
            waitForWorkspaceOpenPreparation: handlers.waitForWorkspaceOpenPreparation
        )
        coordinator.configureLifecycle(with: handlers)
        let root = URL(fileURLWithPath: "/in-memory/coordinator-reopen")
        coordinator.openWorkspace(at: root)
        let firstOpeningGeneration = coordinator.openingGeneration
        #expect(await preparationStarted.waitUntilOpen())
        coordinator.openWorkspace(at: root)
        let secondOpeningGeneration = coordinator.openingGeneration
        #expect(secondOpeningGeneration != firstOpeningGeneration)
        finishPreparation.open()
        #expect(await loaded.waitUntilOpen())
        #expect(preparationCount == 2)
        #expect(restorations == 1)
        #expect(feature.workspaceGeneration == 1)
        #expect(feature.rootNode?.url == root)
        #expect(coordinator.openingGeneration == secondOpeningGeneration)
    }

    private func openingHandlers(wait: @escaping @MainActor () async -> Void) -> WorkspaceSessionCoordinator.LifecycleHandlers {
        .init(prepareForWorkspaceOpen: { _ in }, prepareForWorkspaceClose: { _ in },
              prepareForStandaloneOpen: { _ in }, finishStandaloneClose: {}, beginDocumentClose: { false },
              runServicesCloseConfirmation: { nil }, restoreDebugBreakpoints: { _ in },
              visibilityRules: { .default }, waitForWorkspaceOpenPreparation: wait)
    }

    private func makeOpeningFeature(loaded: TestGate) -> WorkspaceFeatureModel {
        let feature = WorkspaceFeatureModel(
            operations: CoordinatorWorkspaceOperations(), fileOperations: MacWorkspaceFileOperations(),
            gitWatchContextProvider: CoordinatorGitContext(), directoryWatcherFactory: CoordinatorWatcherFactory(),
            workspaceSessionStore: CoordinatorSessionStore()
        )
        feature.configureProjection(
            documentsProvider: { [] }, activeDocumentProvider: { nil }, selectedSidebarProvider: { "project" },
            setSelectedSidebar: { _ in }, restoreSession: { _, _ in }, openFile: { _ in }, notify: { _ in },
            recordHistory: { _, _ in }, relocateHistory: { _, _ in }, relocateOpenDocuments: { _, _ in },
            closeDocuments: { _ in }, processExternalChanges: { _ in false }, reloadProjectServices: {},
            refreshGit: {}, updateHistoryVisibilityRules: { _ in }, onSnapshotLoaded: { _, _ in loaded.open() },
            warmSearchIndex: { _, _ in }, updateSearchIndex: { _, _, _ in }, invalidateSearchIndex: { _, _ in }
        )
        return feature
    }

    @Test
    func cancelledWorkspaceClosePreservesLeaseAndAllowsRetry() {
        let platform = CoordinatorTestPlatformUI()
        let coordinator = WorkspaceSessionCoordinator(
            recentProjectsStore: RecentProjectsStore(store: CoordinatorTestStore()),
            platformUI: platform
        )
        defer { coordinator.clearSession() }
        let url = URL(fileURLWithPath: "/tmp/lithe-cancel-close", isDirectory: true)
        var closeRequests = 0
        var finishes = 0
        coordinator.configureLifecycle(with: .init(
            prepareForWorkspaceOpen: { _ in },
            prepareForWorkspaceClose: { _ in finishes += 1 },
            prepareForStandaloneOpen: { _ in },
            finishStandaloneClose: {},
            beginDocumentClose: {
                closeRequests += 1
                return true
            },
            runServicesCloseConfirmation: { nil },
            restoreDebugBreakpoints: { _ in },
            visibilityRules: { .default }
        ))
        coordinator.beginWorkspace(at: url)
        coordinator.requestCloseWorkspace()
        coordinator.cancelPendingClose()
        coordinator.projectCloseReady()
        #expect(coordinator.pendingCloseRequest == nil)
        #expect(coordinator.workspaceURL == url)
        #expect(platform.stoppedURLs.isEmpty)
        #expect(finishes == 0)

        coordinator.requestCloseWorkspace()
        #expect(closeRequests == 2)
        coordinator.projectCloseReady()
        #expect(finishes == 1)
        #expect(coordinator.workspaceURL == nil)
        #expect(platform.stoppedURLs == [url])
    }

    @Test
    func workspaceCloseWaitsForDocumentsAndReleasesLeaseBeforeCallback() {
        let platform = CoordinatorTestPlatformUI()
        let coordinator = WorkspaceSessionCoordinator(
            recentProjectsStore: RecentProjectsStore(store: CoordinatorTestStore()),
            platformUI: platform
        )
        defer { coordinator.clearSession() }
        let url = URL(fileURLWithPath: "/tmp/lithe-close-workspace", isDirectory: true)
        var closeRequests = 0
        var closedURLs: [URL] = []
        coordinator.configureLifecycle(with: .init(
            prepareForWorkspaceOpen: { _ in },
            prepareForWorkspaceClose: { [weak coordinator] closedURL in
                #expect(coordinator != nil)
                #expect(coordinator?.workspaceURL == nil)
                #expect(platform.stoppedURLs == [url])
                closedURLs.append(closedURL)
            },
            prepareForStandaloneOpen: { _ in },
            finishStandaloneClose: {},
            beginDocumentClose: {
                closeRequests += 1
                return true
            },
            runServicesCloseConfirmation: { nil },
            restoreDebugBreakpoints: { _ in },
            visibilityRules: { .default }
        ))
        coordinator.beginWorkspace(at: url)

        coordinator.requestCloseWorkspace()
        coordinator.requestCloseWorkspace()
        #expect(closeRequests == 1)
        #expect(coordinator.pendingCloseRequest == .workspace)
        #expect(coordinator.workspaceURL == url)
        #expect(platform.stoppedURLs.isEmpty)
        #expect(closedURLs.isEmpty)

        coordinator.projectCloseReady()
        coordinator.projectCloseReady()
        #expect(closedURLs == [url])
        #expect(coordinator.pendingCloseRequest == nil)
        #expect(platform.stoppedURLs == [url])
    }

    @Test
    func runServiceQuestionComesBeforeTheDocumentsAndCancelKeepsTheProject() async {
        let platform = CoordinatorTestPlatformUI()
        let coordinator = WorkspaceSessionCoordinator(
            recentProjectsStore: RecentProjectsStore(store: CoordinatorTestStore()),
            platformUI: platform
        )
        defer { coordinator.clearSession() }
        let url = URL(fileURLWithPath: "/tmp/lithe-run-services-close", isDirectory: true)
        var answers = [false, true]
        var questions = 0
        var closeRequests = 0
        var closedURLs: [URL] = []
        coordinator.configureLifecycle(with: .init(
            prepareForWorkspaceOpen: { _ in },
            prepareForWorkspaceClose: { closedURLs.append($0) },
            prepareForStandaloneOpen: { _ in },
            finishStandaloneClose: {},
            beginDocumentClose: {
                closeRequests += 1
                return false
            },
            runServicesCloseConfirmation: {
                {
                    questions += 1
                    return answers.removeFirst()
                }
            },
            restoreDebugBreakpoints: { _ in },
            visibilityRules: { .default }
        ))
        coordinator.beginWorkspace(at: url)

        coordinator.requestCloseWorkspace()
        #expect(coordinator.pendingCloseRequest == .workspace)
        #expect(closeRequests == 0)
        await waitUntil { coordinator.pendingCloseRequest == nil }
        #expect(questions == 1)
        #expect(closeRequests == 0)
        #expect(coordinator.workspaceURL == url)
        #expect(platform.stoppedURLs.isEmpty)

        coordinator.requestCloseWorkspace()
        await waitUntil { coordinator.workspaceURL == nil }
        #expect(questions == 2)
        #expect(closeRequests == 1)
        #expect(closedURLs == [url])
    }

    /// Yields to the main actor until `condition` holds, for a bounded number of turns.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test
    func standaloneCloseWithoutPendingDocumentsFinishesExactlyOnce() {
        let platform = CoordinatorTestPlatformUI()
        let coordinator = WorkspaceSessionCoordinator(
            recentProjectsStore: RecentProjectsStore(store: CoordinatorTestStore()),
            platformUI: platform
        )
        defer { coordinator.clearSession() }
        let url = URL(fileURLWithPath: "/tmp/lithe-close-file.swift")
        var openedURLs: [URL] = []
        var closeRequests = 0
        var finishes = 0
        coordinator.configureLifecycle(with: .init(
            prepareForWorkspaceOpen: { _ in },
            prepareForWorkspaceClose: { _ in Issue.record("Unexpected workspace close") },
            prepareForStandaloneOpen: { openedURLs.append($0) },
            finishStandaloneClose: { [weak coordinator] in
                #expect(coordinator != nil)
                #expect(coordinator?.standaloneFileURL == nil)
                finishes += 1
            },
            beginDocumentClose: {
                closeRequests += 1
                return false
            },
            runServicesCloseConfirmation: { nil },
            restoreDebugBreakpoints: { _ in },
            visibilityRules: { .default }
        ))

        coordinator.openStandaloneFile(at: url)
        #expect(openedURLs == [url])
        #expect(coordinator.standaloneFileURL == url)
        coordinator.requestCloseStandaloneFile()
        coordinator.requestCloseStandaloneFile()
        coordinator.projectCloseReady()
        #expect(closeRequests == 1)
        #expect(finishes == 1)
        #expect(coordinator.pendingCloseRequest == nil)
        #expect(platform.startedURLs.isEmpty)
        #expect(platform.stoppedURLs.isEmpty)
    }

    @Test
    func workspaceAndStandaloneTransitionsOwnTheSessionStateAndResourceLease() {
        let store = CoordinatorTestStore()
        let platform = CoordinatorTestPlatformUI()
        let coordinator = WorkspaceSessionCoordinator(
            recentProjectsStore: RecentProjectsStore(store: store),
            platformUI: platform
        )
        let workspaceURL = URL(fileURLWithPath: "/tmp/lithe-workspace", isDirectory: true)
        let standaloneURL = URL(fileURLWithPath: "/tmp/lithe-file.swift")

        coordinator.beginWorkspace(at: workspaceURL)
        #expect(coordinator.workspaceURL == workspaceURL.standardizedFileURL)
        #expect(coordinator.standaloneFileURL == nil)
        #expect(platform.startedURLs == [workspaceURL.standardizedFileURL])

        coordinator.beginStandaloneFile(at: standaloneURL)
        #expect(coordinator.workspaceURL == nil)
        #expect(coordinator.standaloneFileURL == standaloneURL.standardizedFileURL)
        #expect(platform.stoppedURLs == [workspaceURL.standardizedFileURL])

        coordinator.clearSession()
        #expect(coordinator.workspaceURL == nil)
        #expect(coordinator.standaloneFileURL == nil)
        #expect(platform.stoppedURLs == [workspaceURL.standardizedFileURL])
    }

    @Test
    func recentProjectMutationsStayOwnedByTheCoordinator() {
        let store = CoordinatorTestStore()
        let coordinator = WorkspaceSessionCoordinator(
            recentProjectsStore: RecentProjectsStore(store: store),
            platformUI: CoordinatorTestPlatformUI()
        )
        let url = URL(fileURLWithPath: "/tmp/lithe-project", isDirectory: true)

        coordinator.recordRecentProject(url)
        #expect(coordinator.recentProjects.map(\.url.path) == [url.standardizedFileURL.path])
        #expect(store.data(forKey: "lithe.recent-projects") != nil)

        coordinator.removeRecentProject(coordinator.recentProjects[0])
        #expect(coordinator.recentProjects.isEmpty)
    }

    @Test
    func recordingAProjectStoresItsBranchForTheWelcomeList() {
        let coordinator = WorkspaceSessionCoordinator(
            recentProjectsStore: RecentProjectsStore(store: CoordinatorTestStore()),
            platformUI: CoordinatorTestPlatformUI(),
            recentProjectBranchReader: CoordinatorBranchReader(branch: "feat/1316-settings-info-tips")
        )
        let url = URL(fileURLWithPath: "/tmp/lithe-project", isDirectory: true)

        coordinator.recordRecentProject(url)

        #expect(coordinator.recentProjects.first?.branch == "feat/1316-settings-info-tips")
    }
}

private struct CoordinatorWorkspaceOperations: WorkspaceOperations {
    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        WorkspaceSnapshot(root: FileNode(url: rootURL, isDirectory: true, children: []), files: [])
    }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private struct CoordinatorGitContext: GitWatchContextProviding {
    func watchContext(for workspace: URL) async -> GitWatchContext? { nil }
}

@MainActor
private final class CoordinatorSessionStore: WorkspaceSessionStoring {
    func load(for workspaceURL: URL) -> WorkspaceSession? { nil }
    func save(_ session: WorkspaceSession, for workspaceURL: URL) {}
}

private struct CoordinatorWatcherFactory: DirectoryWatcherFactory {
    func make(configuration: DirectoryWatchConfiguration, visibilityRules: FileVisibilityRules,
              onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void) -> any DirectoryChangeSource {
        CoordinatorChangeSource()
    }
}

private final class CoordinatorChangeSource: DirectoryChangeSource {
    func start() {}
    func stop() {}
}

@MainActor
private final class CoordinatorTestPlatformUI: PlatformUI {
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []

    func startAccessingProject(_ url: URL) -> Bool {
        startedURLs.append(url)
        return true
    }

    func stopAccessingProject(_ url: URL) {
        stoppedURLs.append(url)
    }

    func chooseDirectory(title: String, prompt: String) -> URL? { nil }
    func chooseFile(title: String, prompt: String) -> URL? { nil }
    func revealInFileBrowser(_ url: URL) {}
    func open(_ url: URL) {}
    func copyToClipboard(_ value: String) {}
    func markdownImageFromClipboard() -> MarkdownImageSource? { nil }
}

private struct CoordinatorBranchReader: RecentProjectBranchReading {
    let branch: String?
    func branch(forProjectAt url: URL) -> String? { branch }
}

private final class CoordinatorTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
