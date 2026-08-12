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

    func stopAllSessions() {
        for model in sessions {
            model.stopTerminalSessions()
        }
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
        modelObservations[model.id] = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func removeClosedSession(_ model: AppModel) {
        guard model.workspaceURL == nil,
              let removedIndex = sessions.firstIndex(where: { $0.id == model.id }) else { return }

        let wasActive = model.id == activeSessionID
        model.shutdownProjectSession()
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
}
