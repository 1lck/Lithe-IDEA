import Foundation
import Testing
@testable import Lithe

@Suite("Workspace session coordinator")
@MainActor
struct WorkspaceSessionCoordinatorTests {
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

private final class CoordinatorTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
