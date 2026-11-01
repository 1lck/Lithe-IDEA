import Combine
import Foundation
import LitheCoreContracts
import LitheWorkspaceModule

/// Owns workspace session state, lifecycle ordering, and native resource leases.
///
/// ProjectSessionManager remains the owner of multiple AppModel instances.
/// This coordinator owns the state and ordering that belong to one AppModel
/// session, including recent-project mutations, security-scoped workspace
/// access, document-close confirmation, and workspace rebuild cancellation.
@MainActor
final class WorkspaceSessionCoordinator: ObservableObject {
    enum CloseRequest: Equatable {
        case workspace
        case standaloneFile
    }

    struct LifecycleHandlers {
        let prepareForWorkspaceOpen: @MainActor (URL) -> Void
        let prepareForWorkspaceClose: @MainActor (URL) -> Void
        let prepareForStandaloneOpen: @MainActor (URL) -> Void
        let finishStandaloneClose: @MainActor () -> Void
        let beginDocumentClose: @MainActor () -> Bool
        /// The question to ask before a workspace close that would stop Run
        /// services, or `nil` when nothing is running.
        let runServicesCloseConfirmation: @MainActor () -> (@MainActor () async -> Bool)?
        let restoreDebugBreakpoints: @MainActor (URL) async -> Void
        let visibilityRules: @MainActor () -> FileVisibilityRules
        var waitForWorkspaceOpenPreparation: @MainActor () async -> Void = {}
    }

    @Published private(set) var workspaceURL: URL?
    @Published private(set) var standaloneFileURL: URL?
    @Published private(set) var recentProjects: [RecentProject]
    @Published private(set) var isActive = true
    private(set) var pendingCloseRequest: CloseRequest?
    /// One session opening, independent of the resource projection's rebuilds.
    private(set) var openingGeneration = 0

    private let recentProjectsStore: RecentProjectsStore
    private let recentProjectBranchReader: any RecentProjectBranchReading
    private weak var platformUI: (any PlatformUI)?
    private let workspaceFeature: WorkspaceFeatureModel?
    private var securityScopedWorkspaceURL: URL?
    private var lifecycleHandlers: LifecycleHandlers?
    private var workspaceRebuildTask: Task<Void, Never>?
    private var workspaceRebuildID = UUID()

    init(
        recentProjectsStore: RecentProjectsStore,
        platformUI: any PlatformUI,
        recentProjectBranchReader: any RecentProjectBranchReading = UnavailableRecentProjectBranchReader(),
        workspaceFeature: WorkspaceFeatureModel? = nil
    ) {
        self.recentProjectsStore = recentProjectsStore
        self.recentProjectBranchReader = recentProjectBranchReader
        self.platformUI = platformUI
        self.workspaceFeature = workspaceFeature
        recentProjects = recentProjectsStore.load()
    }

    func configureLifecycle(with handlers: LifecycleHandlers) {
        lifecycleHandlers = handlers
    }

    func openWorkspace(at url: URL) {
        guard let lifecycleHandlers else {
            assertionFailure("Workspace lifecycle must be configured before opening a workspace.")
            return
        }

        let normalizedURL = url.standardizedFileURL
        workspaceRebuildTask?.cancel()
        workspaceRebuildTask = nil
        if let previousWorkspaceURL = workspaceURL {
            workspaceFeature?.persistWorkspaceSession(for: previousWorkspaceURL)
        }

        lifecycleHandlers.prepareForWorkspaceOpen(normalizedURL)
        beginWorkspace(at: normalizedURL)
        guard workspaceFeature != nil else {
            assertionFailure("Workspace feature is required to open a workspace.")
            return
        }
        recordRecentProject(normalizedURL)
        startWorkspaceRebuild(
            at: normalizedURL,
            operationID: workspaceRebuildID,
            waitForPreparation: lifecycleHandlers.waitForWorkspaceOpenPreparation,
            restoreDebugBreakpoints: lifecycleHandlers.restoreDebugBreakpoints
        )
    }

    func requestCloseWorkspace() {
        guard workspaceURL != nil else { return }
        requestClose(.workspace)
    }

    func requestCloseStandaloneFile() {
        guard standaloneFileURL != nil else { return }
        requestClose(.standaloneFile)
    }

    func projectCloseReady() {
        guard let pendingCloseRequest else { return }
        switch pendingCloseRequest {
        case .workspace:
            finishWorkspaceClose()
        case .standaloneFile:
            finishStandaloneClose()
        }
    }

    func cancelPendingClose() {
        pendingCloseRequest = nil
    }

    func openStandaloneFile(at url: URL) {
        guard let lifecycleHandlers else {
            assertionFailure("Workspace lifecycle must be configured before opening a standalone file.")
            return
        }

        let normalizedURL = url.standardizedFileURL
        workspaceRebuildTask?.cancel()
        workspaceRebuildTask = nil
        lifecycleHandlers.prepareForStandaloneOpen(normalizedURL)
        beginStandaloneFile(at: normalizedURL)
    }

    /// Stops coordinator-owned asynchronous work and releases the native URL
    /// lease. Feature shutdown remains owned by the application's module graph.
    func stopSessionResources() {
        openingGeneration &+= 1
        workspaceRebuildID = UUID()
        workspaceRebuildTask?.cancel()
        workspaceRebuildTask = nil
        pendingCloseRequest = nil
        stopAccessingWorkspace()
    }

    func beginWorkspace(at url: URL) {
        openingGeneration &+= 1
        workspaceRebuildID = UUID()
        stopAccessingWorkspace()
        workspaceURL = url.standardizedFileURL
        standaloneFileURL = nil
        if let workspaceURL {
            _ = startAccessingWorkspace(workspaceURL)
        }
    }

    func beginStandaloneFile(at url: URL) {
        openingGeneration &+= 1
        workspaceRebuildID = UUID()
        stopAccessingWorkspace()
        workspaceURL = nil
        standaloneFileURL = url.standardizedFileURL
    }

    func clearSession() {
        openingGeneration &+= 1
        workspaceRebuildID = UUID()
        workspaceRebuildTask?.cancel()
        workspaceRebuildTask = nil
        pendingCloseRequest = nil
        stopAccessingWorkspace()
        workspaceURL = nil
        standaloneFileURL = nil
    }

    func resetWorkspaceFeature() {
        workspaceFeature?.reset()
    }

    @discardableResult
    func setActive(_ isActive: Bool) -> Bool {
        guard self.isActive != isActive else { return false }
        self.isActive = isActive
        return true
    }

    func recordRecentProject(_ url: URL) {
        recentProjects = recentProjectsStore.record(
            url,
            branch: recentProjectBranchReader.branch(forProjectAt: url),
            in: recentProjects
        )
    }

    func removeRecentProject(_ project: RecentProject) {
        recentProjects = recentProjectsStore.remove(project, from: recentProjects)
    }

    func refreshRecentProjects() {
        recentProjects = recentProjectsStore.load()
    }

    @discardableResult
    func startAccessingWorkspace(_ url: URL) -> Bool {
        stopAccessingWorkspace()
        guard platformUI?.startAccessingProject(url) == true else { return false }
        securityScopedWorkspaceURL = url
        return true
    }

    func stopAccessingWorkspace() {
        guard let securityScopedWorkspaceURL else { return }
        platformUI?.stopAccessingProject(securityScopedWorkspaceURL)
        self.securityScopedWorkspaceURL = nil
    }

    private func requestClose(_ request: CloseRequest) {
        guard pendingCloseRequest == nil else { return }
        guard let lifecycleHandlers else {
            assertionFailure("Workspace lifecycle must be configured before closing a session.")
            return
        }
        pendingCloseRequest = request
        // Asked before the documents: they close one by one, so a later cancel
        // would leave the project open without them. Nothing stops until the
        // workspace close finishes.
        if request == .workspace, let confirm = lifecycleHandlers.runServicesCloseConfirmation() {
            Task { @MainActor [weak self] in
                let confirmed = await confirm()
                guard let self, self.pendingCloseRequest == request else { return }
                guard confirmed else {
                    self.pendingCloseRequest = nil
                    return
                }
                self.beginDocumentClose()
            }
            return
        }
        beginDocumentClose()
    }

    private func beginDocumentClose() {
        guard let lifecycleHandlers else { return }
        if !lifecycleHandlers.beginDocumentClose() {
            projectCloseReady()
        }
    }

    private func finishWorkspaceClose() {
        guard let lifecycleHandlers, let workspaceURL else { return }
        workspaceRebuildTask?.cancel()
        workspaceRebuildTask = nil
        workspaceFeature?.persistWorkspaceSession(for: workspaceURL)
        clearSession()
        lifecycleHandlers.prepareForWorkspaceClose(workspaceURL)
    }

    private func finishStandaloneClose() {
        guard let lifecycleHandlers else { return }
        clearSession()
        lifecycleHandlers.finishStandaloneClose()
    }

    private func startWorkspaceRebuild(
        at workspaceURL: URL,
        operationID: UUID,
        waitForPreparation: @escaping @MainActor () async -> Void,
        restoreDebugBreakpoints: @escaping @MainActor (URL) async -> Void
    ) {
        guard let workspaceFeature else {
            assertionFailure("Workspace feature is required to rebuild a workspace.")
            return
        }
        workspaceRebuildTask = Task { @MainActor [weak self, workspaceFeature] in
            await waitForPreparation()
            guard let self, !Task.isCancelled, self.workspaceRebuildID == operationID,
                  self.workspaceURL == workspaceURL.standardizedFileURL else { return }
            // The old graph may stop this same UI projection. Begin the new
            // lifetime only after that teardown and its resource rebinding finish.
            let rules = self.lifecycleHandlers?.visibilityRules() ?? .default
            workspaceFeature.beginWorkspace(at: workspaceURL, visibilityRules: rules)
            let generation = workspaceFeature.workspaceGeneration
            await restoreDebugBreakpoints(workspaceURL)
            guard !Task.isCancelled, self.workspaceRebuildID == operationID,
                  self.isCurrentWorkspace(workspaceURL, generation: generation) else {
                return
            }
            _ = await workspaceFeature.rebuild(
                at: workspaceURL,
                rules: rules,
                isCurrent: { [weak self] in
                    self?.workspaceRebuildID == operationID && self?.isCurrentWorkspace(workspaceURL, generation: generation) == true
                }
            )
        }
    }

    private func isCurrentWorkspace(_ url: URL, generation: Int) -> Bool {
        workspaceURL == url.standardizedFileURL
            && workspaceFeature?.workspaceGeneration == generation
    }
}
