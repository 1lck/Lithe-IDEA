import Combine
import Foundation

enum ProjectOpenPlacement: String, CaseIterable {
    case thisWindow
    case newWindow
}

struct PendingProjectOpen: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let sourceSessionID: UUID

    var projectName: String { url.lastPathComponent }
}

/// Identifies which top-level window hosts a project session.
enum ProjectWindowScope: Equatable, Sendable {
    case primary
    case dedicated(UUID)
}

@MainActor
final class ProjectSessionManager: ObservableObject {
    @Published private(set) var sessions: [AppModel]
    @Published private(set) var activeSessionID: UUID
    @Published var pendingProjectOpen: PendingProjectOpen?

    private let settings: AppSettings
    private let modelFactory: () -> AppModel
    /// Presents or focuses the dedicated SwiftUI window for a session ID.
    private let projectWindowPresenter: (UUID) -> Void
    private var dedicatedWindowSessionIDs: Set<UUID> = []
    private var modelObservations: [UUID: AnyCancellable] = [:]
    // A closed model can disappear from `sessions` before its asynchronous
    // module teardown finishes. Keep the task here so the manager remains the
    // owner of that cleanup until it has completed.
    private var sessionShutdownTasks: [UUID: Task<Void, Never>] = [:]

    init(
        settings: AppSettings,
        modelFactory: @escaping () -> AppModel,
        projectWindowPresenter: @escaping (UUID) -> Void = { _ in }
    ) {
        self.settings = settings
        self.modelFactory = modelFactory
        self.projectWindowPresenter = projectWindowPresenter

        let initialModel = modelFactory()
        sessions = [initialModel]
        activeSessionID = initialModel.id
        configure(initialModel)
    }

    var activeModel: AppModel {
        sessions.first(where: { $0.id == activeSessionID }) ?? sessions[0]
    }

    var openProjects: [AppModel] {
        sessions.filter { $0.workspaceURL != nil }
    }

    var primarySessions: [AppModel] {
        sessions.filter { !dedicatedWindowSessionIDs.contains($0.id) }
    }

    var primaryOpenProjects: [AppModel] {
        primarySessions.filter { $0.workspaceURL != nil }
    }

    var hasUnsavedDocuments: Bool {
        sessions.contains(where: \.hasUnsavedDocuments)
    }

    var unsavedDocumentNames: [String] {
        sessions.flatMap { model in
            model.openDocuments
                .filter(\.isDirty)
                .map { "\(model.projectName)/\($0.displayName)" }
        }
    }

    @discardableResult
    func saveAllDocuments() -> Bool {
        var savedAll = true
        for model in sessions where !model.saveAllDocuments() {
            savedAll = false
        }
        return savedAll
    }

    func isDedicatedWindowSession(_ id: UUID) -> Bool {
        dedicatedWindowSessionIDs.contains(id)
    }

    func session(for id: UUID) -> AppModel? {
        sessions.first(where: { $0.id == id })
    }

    func openProjects(in scope: ProjectWindowScope) -> [AppModel] {
        switch scope {
        case .primary:
            return primaryOpenProjects
        case .dedicated(let sessionID):
            return openProjects.filter { $0.id == sessionID }
        }
    }

    func openStartupProject(_ url: URL) {
        activeModel.openProjectDirectly(url.standardizedFileURL)
        refreshRecentProjects()
    }

    func openStandaloneFile(_ url: URL) {
        let model: AppModel
        if activeModel.workspaceURL == nil && activeModel.standaloneFileURL == nil {
            model = activeModel
        } else {
            activeModel.setProjectSessionActive(false)
            model = modelFactory()
            sessions.append(model)
            configure(model)
            activeSessionID = model.id
        }
        model.openStandaloneFile(url.standardizedFileURL)
    }

    func requestOpenProject(_ url: URL, from sourceSessionID: UUID) {
        let normalizedURL = url.standardizedFileURL
        if let existing = openProjects.first(where: {
            $0.workspaceURL?.standardizedFileURL == normalizedURL
        }) {
            activateSession(existing.id)
            return
        }

        if openProjects.isEmpty {
            openInThisWindow(normalizedURL)
            return
        }

        switch settings.projectOpenBehavior {
        case .ask:
            pendingProjectOpen = PendingProjectOpen(
                url: normalizedURL,
                sourceSessionID: sourceSessionID
            )
        case .thisWindow:
            openInThisWindow(normalizedURL)
        case .newWindow:
            openInNewWindow(normalizedURL)
        }
    }

    func resolvePendingOpen(
        _ request: PendingProjectOpen,
        placement: ProjectOpenPlacement,
        doNotAskAgain: Bool
    ) {
        guard pendingProjectOpen?.id == request.id else { return }
        pendingProjectOpen = nil

        if doNotAskAgain {
            settings.projectOpenBehavior = placement == .thisWindow ? .thisWindow : .newWindow
        }

        switch placement {
        case .thisWindow:
            openInThisWindow(request.url)
        case .newWindow:
            openInNewWindow(request.url)
        }
    }

    func cancelPendingOpen() {
        pendingProjectOpen = nil
    }

    func activateSession(_ id: UUID) {
        guard let nextModel = sessions.first(where: { $0.id == id }) else { return }
        if id != activeSessionID {
            activeModel.setProjectSessionActive(false)
            activeSessionID = id
            nextModel.setProjectSessionActive(true)
            nextModel.refreshRecentProjects()
        }
        if dedicatedWindowSessionIDs.contains(id) {
            projectWindowPresenter(id)
        }
    }

    func closeActiveProject() {
        activeModel.closeProject()
    }

    @discardableResult
    func requestCloseActiveWorkbenchItem() -> Bool {
        activeModel.requestCloseActiveWorkbenchItem()
    }

    func requestCloseActiveSession() -> Bool {
        if activeModel.workspaceURL != nil {
            closeActiveProject()
            return false
        }
        if activeModel.standaloneFileURL != nil {
            if activeModel.hasUnsavedDocuments {
                activeModel.closeStandaloneFile()
                return false
            }
            return true
        }
        return true
    }

    /// Primary window: dismiss instead of showing welcome when other project
    /// windows still hold open workspaces.
    var shouldDismissPrimaryWindowWhenClosingActiveSession: Bool {
        primaryOpenProjects.count <= 1 && openProjects.contains(where: {
            dedicatedWindowSessionIDs.contains($0.id)
        })
    }

    func resetForProjectWindowClose() async {
        let previousSessions = sessions

        pendingProjectOpen = nil
        dedicatedWindowSessionIDs.removeAll()
        modelObservations.removeAll()
        for model in previousSessions {
            await scheduleSessionShutdown(for: model).value
        }
        await waitForPendingSessionShutdowns()

        let replacement = modelFactory()
        configure(replacement)
        sessions = [replacement]
        activeSessionID = replacement.id
    }

    /// Tears down only the primary-window sessions so dedicated project windows
    /// can keep running after the welcome/host window is dismissed.
    func resetPrimaryWindowSessions() async {
        let primary = primarySessions
        pendingProjectOpen = nil
        for model in primary {
            modelObservations[model.id] = nil
            await scheduleSessionShutdown(for: model).value
            sessions.removeAll { $0.id == model.id }
        }
        await waitForPendingSessionShutdowns()

        if let next = sessions.first(where: { $0.workspaceURL != nil })
            ?? sessions.first {
            activeSessionID = next.id
            next.setProjectSessionActive(true)
        } else {
            let replacement = modelFactory()
            configure(replacement)
            sessions = [replacement]
            activeSessionID = replacement.id
        }
    }

    /// Tears down one dedicated project window without creating a welcome shell
    /// in that window. Restores a primary welcome session only when nothing remains.
    func resetDedicatedWindowSession(_ id: UUID) async {
        guard let model = sessions.first(where: { $0.id == id }) else { return }
        dedicatedWindowSessionIDs.remove(id)
        modelObservations[id] = nil
        let wasActive = activeSessionID == id
        await scheduleSessionShutdown(for: model).value
        sessions.removeAll { $0.id == id }
        await waitForPendingSessionShutdowns()

        if sessions.isEmpty {
            let replacement = modelFactory()
            configure(replacement)
            sessions = [replacement]
            activeSessionID = replacement.id
            return
        }

        if wasActive {
            if let primaryProject = primaryOpenProjects.first {
                activeSessionID = primaryProject.id
                primaryProject.setProjectSessionActive(true)
            } else if let primary = primarySessions.first {
                activeSessionID = primary.id
                primary.setProjectSessionActive(true)
            } else if let next = sessions.first {
                activeSessionID = next.id
                next.setProjectSessionActive(true)
            }
        }
    }

    func closeProject(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        if id != activeSessionID {
            activateSession(id)
        }
        activeModel.closeProject()
    }

    func stopAllSessions() async {
        for model in sessions {
            await scheduleSessionShutdown(for: model).value
        }
        await waitForPendingSessionShutdowns()
    }

    func resumeGitObservationAfterActivation() async {
        for model in openProjects {
            await model.resumeGitObservationAfterActivation()
        }
    }

    private func openInThisWindow(_ url: URL) {
        let model: AppModel
        if let emptyPrimary = primarySessions.first(where: {
            $0.workspaceURL == nil && $0.standaloneFileURL == nil
        }) {
            model = emptyPrimary
            if model.id != activeSessionID {
                activeModel.setProjectSessionActive(false)
                activeSessionID = model.id
                model.setProjectSessionActive(true)
            }
        } else if activeModel.workspaceURL == nil && !isDedicatedWindowSession(activeModel.id) {
            model = activeModel
        } else {
            activeModel.setProjectSessionActive(false)
            model = modelFactory()
            sessions.append(model)
            configure(model)
            activeSessionID = model.id
        }
        model.openProjectDirectly(url)
        refreshRecentProjects()
    }

    private func openInNewWindow(_ url: URL) {
        activeModel.setProjectSessionActive(false)
        let model = modelFactory()
        sessions.append(model)
        dedicatedWindowSessionIDs.insert(model.id)
        configure(model)
        activeSessionID = model.id
        model.setProjectSessionActive(true)
        model.openProjectDirectly(url)
        refreshRecentProjects()
        projectWindowPresenter(model.id)
    }

    private func configure(_ model: AppModel) {
        model.configureProjectSession(
            requestOpen: { [weak self, weak model] url in
                guard let self, let model else { return }
                self.requestOpenProject(url, from: model.id)
            },
            didClose: { [weak self, weak model] in
                guard let self, let model else { return }
                self.removeClosedSession(model)
            }
        )
        // Only workspace open/close should wake the window chrome. Relaying
        // every AppModel tick rebuilds every mounted project session.
        modelObservations[model.id] = model.workspaceSessionCoordinator.$workspaceURL
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    private func removeClosedSession(_ model: AppModel) {
        guard model.workspaceURL == nil,
              let removedIndex = sessions.firstIndex(where: { $0.id == model.id }) else { return }

        let wasDedicated = dedicatedWindowSessionIDs.remove(model.id) != nil
        let wasActive = model.id == activeSessionID
        _ = scheduleSessionShutdown(for: model)
        modelObservations[model.id] = nil
        sessions.remove(at: removedIndex)

        if sessions.isEmpty {
            let replacement = modelFactory()
            sessions = [replacement]
            activeSessionID = replacement.id
            configure(replacement)
            return
        }

        if wasActive {
            let preferred: AppModel?
            if wasDedicated {
                preferred = primaryOpenProjects.first ?? primarySessions.first ?? sessions.first
            } else {
                let primary = primarySessions
                if let nextPrimaryProject = primary.first(where: { $0.workspaceURL != nil }) {
                    preferred = nextPrimaryProject
                } else if let nextPrimary = primary.first {
                    preferred = nextPrimary
                } else {
                    preferred = sessions.first
                }
            }
            if let preferred {
                activeSessionID = preferred.id
                preferred.setProjectSessionActive(true)
            }
        }
    }

    private func refreshRecentProjects() {
        for model in sessions {
            model.refreshRecentProjects()
        }
    }

    private func scheduleSessionShutdown(for model: AppModel) -> Task<Void, Never> {
        if let existingTask = sessionShutdownTasks[model.id] {
            return existingTask
        }

        let modelID = model.id
        let task = Task { @MainActor [weak self, model] in
            defer { self?.sessionShutdownTasks[modelID] = nil }
            await model.shutdownProjectSession()
        }
        sessionShutdownTasks[modelID] = task
        return task
    }

    private func waitForPendingSessionShutdowns() async {
        while !sessionShutdownTasks.isEmpty {
            let pendingTasks = Array(sessionShutdownTasks.values)
            for task in pendingTasks {
                await task.value
            }
        }
    }
}

extension ProjectSessionManager: UnsavedDocumentHandling {}

@MainActor
final class ProjectWindowLauncher: ObservableObject {
    var presentProjectWindow: ((UUID) -> Void)?

    func present(_ sessionID: UUID) {
        presentProjectWindow?(sessionID)
    }
}
