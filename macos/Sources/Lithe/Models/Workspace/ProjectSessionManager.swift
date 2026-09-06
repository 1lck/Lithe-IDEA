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

@MainActor
final class ProjectSessionManager: ObservableObject {
    @Published private(set) var sessions: [AppModel]
    @Published private(set) var activeSessionID: UUID
    @Published var pendingProjectOpen: PendingProjectOpen?

    private let settings: AppSettings
    private let modelFactory: () -> AppModel
    private let newWindowOpener: (URL) -> Void
    private var modelObservations: [UUID: AnyCancellable] = [:]
    // A closed model can disappear from `sessions` before its asynchronous
    // module teardown finishes. Keep the task here so the manager remains the
    // owner of that cleanup until it has completed.
    private var sessionShutdownTasks: [UUID: Task<Void, Never>] = [:]

    init(
        settings: AppSettings,
        modelFactory: @escaping () -> AppModel,
        newWindowOpener: @escaping (URL) -> Void
    ) {
        self.settings = settings
        self.modelFactory = modelFactory
        self.newWindowOpener = newWindowOpener

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
            activeModel.openProjectDirectly(normalizedURL)
            refreshRecentProjects()
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
            newWindowOpener(normalizedURL)
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
            newWindowOpener(request.url)
        }
    }

    func cancelPendingOpen() {
        pendingProjectOpen = nil
    }

    func activateSession(_ id: UUID) {
        guard id != activeSessionID,
              let nextModel = sessions.first(where: { $0.id == id }) else { return }
        activeModel.setProjectSessionActive(false)
        activeSessionID = id
        nextModel.setProjectSessionActive(true)
        nextModel.refreshRecentProjects()
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

    func resetForProjectWindowClose() async {
        let previousSessions = sessions

        pendingProjectOpen = nil
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

    func closeProject(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        if id != activeSessionID {
            activateSession(id)
        }
        activeModel.closeProject()
    }

    @discardableResult
    func saveAllDocuments() -> Bool {
        var savedAll = true
        for model in sessions where !model.saveAllDocuments() {
            savedAll = false
        }
        return savedAll
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
        if activeModel.workspaceURL == nil {
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
            let nextIndex = min(removedIndex, sessions.count - 1)
            activeSessionID = sessions[nextIndex].id
            sessions[nextIndex].setProjectSessionActive(true)
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
