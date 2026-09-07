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

/// Identifies which top-level window hosts project sessions.
enum ProjectWindowScope: Hashable, Equatable, Sendable {
    case primary
    case dedicated(UUID)

    var dedicatedWindowID: UUID? {
        if case .dedicated(let id) = self { return id }
        return nil
    }
}

@MainActor
final class ProjectSessionManager: ObservableObject {
    @Published private(set) var sessions: [AppModel]
    /// Active session inside each top-level window.
    @Published private(set) var activeSessionIDs: [ProjectWindowScope: UUID] = [:]
    /// Window that currently owns menu-bar commands and focus-driven actions.
    @Published private(set) var focusedScope: ProjectWindowScope = .primary
    @Published var pendingProjectOpen: PendingProjectOpen?

    private let settings: AppSettings
    private let modelFactory: () -> AppModel
    private let projectWindowPresenter: (UUID) -> Void
    private let projectWindowDismisser: (UUID) -> Void
    private var sessionScopes: [UUID: ProjectWindowScope] = [:]
    private var modelObservations: [UUID: AnyCancellable] = [:]
    // A closed model can disappear from `sessions` before its asynchronous
    // module teardown finishes. Keep the task here so the manager remains the
    // owner of that cleanup until it has completed.
    private var sessionShutdownTasks: [UUID: Task<Void, Never>] = [:]

    init(
        settings: AppSettings,
        modelFactory: @escaping () -> AppModel,
        projectWindowPresenter: @escaping (UUID) -> Void = { _ in },
        projectWindowDismisser: @escaping (UUID) -> Void = { _ in }
    ) {
        self.settings = settings
        self.modelFactory = modelFactory
        self.projectWindowPresenter = projectWindowPresenter
        self.projectWindowDismisser = projectWindowDismisser

        let initialModel = modelFactory()
        sessions = [initialModel]
        sessionScopes[initialModel.id] = .primary
        activeSessionIDs[.primary] = initialModel.id
        focusedScope = .primary
        configure(initialModel)
    }

    /// Focused window's active session. Menu commands and app-level chrome use this.
    var activeSessionID: UUID {
        activeSessionID(in: focusedScope)
    }

    var activeModel: AppModel {
        sessions.first(where: { $0.id == activeSessionID }) ?? sessions[0]
    }

    var openProjects: [AppModel] {
        sessions.filter { $0.workspaceURL != nil }
    }

    var primarySessions: [AppModel] {
        sessions(in: .primary)
    }

    var primaryOpenProjects: [AppModel] {
        openProjects(in: .primary)
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

    func scope(for sessionID: UUID) -> ProjectWindowScope {
        sessionScopes[sessionID] ?? .primary
    }

    func isDedicatedWindowSession(_ id: UUID) -> Bool {
        if case .dedicated = scope(for: id) {
            return true
        }
        return false
    }

    func session(for id: UUID) -> AppModel? {
        sessions.first(where: { $0.id == id })
    }

    func sessions(in scope: ProjectWindowScope) -> [AppModel] {
        sessions.filter { sessionScopes[$0.id] == scope }
    }

    func openProjects(in scope: ProjectWindowScope) -> [AppModel] {
        sessions(in: scope).filter { $0.workspaceURL != nil }
    }

    func activeSessionID(in scope: ProjectWindowScope) -> UUID {
        if let id = activeSessionIDs[scope], sessions.contains(where: { $0.id == id }) {
            return id
        }
        return sessions(in: scope).first?.id
            ?? sessions.first?.id
            ?? UUID()
    }

    func activeModel(in scope: ProjectWindowScope) -> AppModel {
        let id = activeSessionID(in: scope)
        return sessions.first(where: { $0.id == id })
            ?? sessions(in: scope).first
            ?? sessions[0]
    }

    func noteWindowBecameKey(_ scope: ProjectWindowScope) {
        guard focusedScope != scope else {
            syncProjectSessionActivation(for: scope)
            return
        }
        let previous = activeModel
        focusedScope = scope
        previous.setProjectSessionActive(false)
        syncProjectSessionActivation(for: scope)
        activeModel(in: scope).refreshRecentProjects()
        objectWillChange.send()
    }

    func ensurePrimaryWindowAvailable() {
        if sessions(in: .primary).isEmpty {
            let replacement = modelFactory()
            sessions.append(replacement)
            sessionScopes[replacement.id] = .primary
            activeSessionIDs[.primary] = replacement.id
            configure(replacement)
        }
        focusedScope = .primary
        syncProjectSessionActivation(for: .primary)
        // Re-presenting the primary WindowGroup is handled by the app scene;
        // dedicated windows keep using their own presentation values.
        objectWillChange.send()
    }

    func openStartupProject(_ url: URL) {
        let model = activeModel(in: .primary)
        setActiveSession(model.id, in: .primary)
        focusedScope = .primary
        model.openProjectDirectly(url.standardizedFileURL)
        refreshRecentProjects()
    }

    func openStandaloneFile(_ url: URL) {
        let scope = focusedScope
        let active = activeModel(in: scope)
        let model: AppModel
        if active.workspaceURL == nil && active.standaloneFileURL == nil {
            model = active
        } else {
            active.setProjectSessionActive(false)
            model = modelFactory()
            sessions.append(model)
            sessionScopes[model.id] = scope
            configure(model)
            setActiveSession(model.id, in: scope)
        }
        model.openStandaloneFile(url.standardizedFileURL)
        syncProjectSessionActivation(for: scope)
    }

    func requestOpenProject(_ url: URL, from sourceSessionID: UUID) {
        let normalizedURL = url.standardizedFileURL
        let sourceScope = scope(for: sourceSessionID)
        if let existing = openProjects.first(where: {
            $0.workspaceURL?.standardizedFileURL == normalizedURL
        }) {
            activateSession(existing.id)
            return
        }

        if openProjects.isEmpty {
            openInThisWindow(normalizedURL, scope: sourceScope)
            return
        }

        switch settings.projectOpenBehavior {
        case .ask:
            pendingProjectOpen = PendingProjectOpen(
                url: normalizedURL,
                sourceSessionID: sourceSessionID
            )
        case .thisWindow:
            openInThisWindow(normalizedURL, scope: sourceScope)
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

        let sourceScope = scope(for: request.sourceSessionID)
        switch placement {
        case .thisWindow:
            openInThisWindow(request.url, scope: sourceScope)
        case .newWindow:
            openInNewWindow(request.url)
        }
    }

    func cancelPendingOpen() {
        pendingProjectOpen = nil
    }

    func activateSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        let scope = scope(for: id)
        let previousFocused = focusedScope
        let previousActive = activeModel(in: scope)

        if previousFocused != scope {
            activeModel(in: previousFocused).setProjectSessionActive(false)
            focusedScope = scope
        }
        if previousActive.id != id {
            previousActive.setProjectSessionActive(false)
            setActiveSession(id, in: scope)
        }
        syncProjectSessionActivation(for: scope)
        activeModel(in: scope).refreshRecentProjects()

        if case .dedicated(let windowID) = scope {
            projectWindowPresenter(windowID)
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
        let model = activeModel
        if model.workspaceURL != nil {
            model.closeProject()
            return false
        }
        if model.standaloneFileURL != nil {
            if model.hasUnsavedDocuments {
                model.closeStandaloneFile()
                return false
            }
            return true
        }
        return true
    }

    /// Primary window: dismiss instead of showing welcome when other project
    /// windows still hold open workspaces.
    var shouldDismissPrimaryWindowWhenClosingActiveSession: Bool {
        primaryOpenProjects.count <= 1 && openProjects.contains(where: { isDedicatedWindowSession($0.id) })
    }

    /// Legacy name kept for existing window handlers. Only resets primary-window
    /// sessions so dedicated project windows stay alive.
    func resetForProjectWindowClose() async {
        await resetPrimaryWindowSessions()
    }

    /// Tears down only the primary-window sessions so dedicated project windows
    /// can keep running after the welcome/host window is dismissed.
    func resetPrimaryWindowSessions() async {
        let primary = sessions(in: .primary)
        pendingProjectOpen = nil
        for model in primary {
            modelObservations[model.id] = nil
            sessionScopes[model.id] = nil
            await scheduleSessionShutdown(for: model).value
            sessions.removeAll { $0.id == model.id }
        }
        activeSessionIDs[.primary] = nil
        await waitForPendingSessionShutdowns()

        if sessions.isEmpty {
            let replacement = modelFactory()
            sessions = [replacement]
            sessionScopes = [replacement.id: .primary]
            activeSessionIDs = [.primary: replacement.id]
            focusedScope = .primary
            configure(replacement)
            syncProjectSessionActivation(for: .primary)
            objectWillChange.send()
            return
        }

        if focusedScope == .primary {
            if let dedicatedProject = openProjects.first(where: { isDedicatedWindowSession($0.id) }) {
                focusedScope = scope(for: dedicatedProject.id)
                setActiveSession(dedicatedProject.id, in: focusedScope)
                syncProjectSessionActivation(for: focusedScope)
            } else if let any = sessions.first {
                focusedScope = scope(for: any.id)
                setActiveSession(any.id, in: focusedScope)
                syncProjectSessionActivation(for: focusedScope)
            }
        }

        objectWillChange.send()
    }

    /// Tears down one dedicated project window without creating a welcome shell
    /// in that window. Restores a primary welcome session only when nothing remains.
    func resetDedicatedWindowSession(windowID: UUID) async {
        let scope = ProjectWindowScope.dedicated(windowID)
        let scopedSessions = sessions(in: scope)
        guard !scopedSessions.isEmpty else {
            projectWindowDismisser(windowID)
            return
        }

        pendingProjectOpen = nil
        for model in scopedSessions {
            modelObservations[model.id] = nil
            sessionScopes[model.id] = nil
            await scheduleSessionShutdown(for: model).value
            sessions.removeAll { $0.id == model.id }
        }
        activeSessionIDs[scope] = nil
        await waitForPendingSessionShutdowns()
        projectWindowDismisser(windowID)

        if sessions.isEmpty {
            let replacement = modelFactory()
            sessions = [replacement]
            sessionScopes[replacement.id] = .primary
            activeSessionIDs = [.primary: replacement.id]
            focusedScope = .primary
            configure(replacement)
            syncProjectSessionActivation(for: .primary)
            objectWillChange.send()
            return
        }

        if focusedScope == scope {
            if let primaryProject = primaryOpenProjects.first {
                focusedScope = .primary
                setActiveSession(primaryProject.id, in: .primary)
            } else if let primary = primarySessions.first {
                focusedScope = .primary
                setActiveSession(primary.id, in: .primary)
            } else if let next = sessions.first {
                focusedScope = self.scope(for: next.id)
                setActiveSession(next.id, in: focusedScope)
            }
            syncProjectSessionActivation(for: focusedScope)
        }

        objectWillChange.send()
    }

    func closeProject(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        activateSession(id)
        activeModel(in: scope(for: id)).closeProject()
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

    private func openInThisWindow(_ url: URL, scope: ProjectWindowScope) {
        let scoped = sessions(in: scope)
        let model: AppModel
        if let empty = scoped.first(where: {
            $0.workspaceURL == nil && $0.standaloneFileURL == nil
        }) {
            model = empty
        } else if let active = scoped.first(where: { $0.id == activeSessionID(in: scope) }),
                  active.workspaceURL == nil {
            model = active
        } else {
            activeModel(in: scope).setProjectSessionActive(false)
            model = modelFactory()
            sessions.append(model)
            sessionScopes[model.id] = scope
            configure(model)
        }

        setActiveSession(model.id, in: scope)
        focusedScope = scope
        model.setProjectSessionActive(true)
        model.openProjectDirectly(url)
        refreshRecentProjects()

        if case .dedicated(let windowID) = scope {
            projectWindowPresenter(windowID)
        }
        objectWillChange.send()
    }

    private func openInNewWindow(_ url: URL) {
        activeModel.setProjectSessionActive(false)
        let model = modelFactory()
        let windowID = model.id
        let scope = ProjectWindowScope.dedicated(windowID)
        sessions.append(model)
        sessionScopes[model.id] = scope
        configure(model)
        setActiveSession(model.id, in: scope)
        focusedScope = scope
        model.setProjectSessionActive(true)
        model.openProjectDirectly(url)
        refreshRecentProjects()
        projectWindowPresenter(windowID)
        objectWillChange.send()
    }

    private func setActiveSession(_ id: UUID, in scope: ProjectWindowScope) {
        activeSessionIDs[scope] = id
    }

    private func syncProjectSessionActivation(for scope: ProjectWindowScope) {
        let activeID = activeSessionID(in: scope)
        for model in sessions {
            model.setProjectSessionActive(model.id == activeID && focusedScope == scope)
        }
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

        let scope = scope(for: model.id)
        let wasActiveInScope = activeSessionID(in: scope) == model.id
        _ = scheduleSessionShutdown(for: model)
        modelObservations[model.id] = nil
        sessionScopes[model.id] = nil
        sessions.remove(at: removedIndex)

        let remainingInScope = sessions(in: scope)
        if remainingInScope.isEmpty {
            activeSessionIDs[scope] = nil
            if case .dedicated(let windowID) = scope {
                projectWindowDismisser(windowID)
            }
        }

        if sessions.isEmpty {
            let replacement = modelFactory()
            sessions = [replacement]
            sessionScopes = [replacement.id: .primary]
            activeSessionIDs = [.primary: replacement.id]
            focusedScope = .primary
            configure(replacement)
            syncProjectSessionActivation(for: .primary)
            objectWillChange.send()
            return
        }

        if wasActiveInScope, let next = remainingInScope.first {
            setActiveSession(next.id, in: scope)
            if focusedScope == scope {
                next.setProjectSessionActive(true)
            }
        } else if remainingInScope.isEmpty, focusedScope == scope {
            if let primaryProject = primaryOpenProjects.first {
                focusedScope = .primary
                setActiveSession(primaryProject.id, in: .primary)
            } else if let primary = primarySessions.first {
                focusedScope = .primary
                setActiveSession(primary.id, in: .primary)
            } else if let next = sessions.first {
                focusedScope = self.scope(for: next.id)
                setActiveSession(next.id, in: focusedScope)
            }
            syncProjectSessionActivation(for: focusedScope)
        }

        objectWillChange.send()
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
