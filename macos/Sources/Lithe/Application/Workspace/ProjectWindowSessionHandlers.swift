import Foundation

@MainActor
final class PrimaryProjectWindowSessions: ProjectWindowSessionHandling {
    private let manager: ProjectSessionManager

    init(manager: ProjectSessionManager) {
        self.manager = manager
    }

    var hasUnsavedDocuments: Bool {
        manager.primarySessions.contains(where: \.hasUnsavedDocuments)
    }

    var unsavedDocumentNames: [String] {
        manager.primarySessions.flatMap { model in
            model.openDocuments
                .filter(\.isDirty)
                .map { "\(model.projectName)/\($0.displayName)" }
        }
    }

    var hasActiveProject: Bool {
        manager.activeModel(in: .primary).workspaceURL != nil
    }

    var hasActiveStandaloneFile: Bool {
        manager.activeModel(in: .primary).standaloneFileURL != nil
    }

    var shouldDismissWindowWhenClosingActiveSession: Bool {
        manager.shouldDismissPrimaryWindowWhenClosingActiveSession
    }

    var windowScope: ProjectWindowScope { .primary }

    func closeActiveProject() {
        manager.activeModel(in: .primary).closeProject()
    }

    func requestCloseActiveWorkbenchItem() -> Bool {
        manager.activeModel(in: .primary).requestCloseActiveWorkbenchItem()
    }

    func requestCloseActiveSession() -> Bool {
        let model = manager.activeModel(in: .primary)
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

    func saveAllDocuments() -> Bool {
        var savedAll = true
        for model in manager.primarySessions where !model.saveAllDocuments() {
            savedAll = false
        }
        return savedAll
    }

    func resetForProjectWindowClose() async {
        await manager.resetPrimaryWindowSessions()
    }

    func noteWindowBecameKey() {
        manager.noteWindowBecameKey(.primary)
    }
}

@MainActor
final class DedicatedProjectWindowSessions: ProjectWindowSessionHandling {
    private let manager: ProjectSessionManager
    private let windowID: UUID

    init(manager: ProjectSessionManager, windowID: UUID) {
        self.manager = manager
        self.windowID = windowID
    }

    private var scope: ProjectWindowScope { .dedicated(windowID) }

    private var scopedSessions: [AppModel] {
        manager.sessions(in: scope)
    }

    private var activeModel: AppModel {
        manager.activeModel(in: scope)
    }

    var hasUnsavedDocuments: Bool {
        scopedSessions.contains(where: \.hasUnsavedDocuments)
    }

    var unsavedDocumentNames: [String] {
        scopedSessions.flatMap { model in
            model.openDocuments
                .filter(\.isDirty)
                .map { "\(model.projectName)/\($0.displayName)" }
        }
    }

    var hasActiveProject: Bool {
        activeModel.workspaceURL != nil
    }

    var hasActiveStandaloneFile: Bool {
        activeModel.standaloneFileURL != nil
    }

    var shouldDismissWindowWhenClosingActiveSession: Bool { true }

    var windowScope: ProjectWindowScope { scope }

    func closeActiveProject() {
        activeModel.closeProject()
    }

    func requestCloseActiveWorkbenchItem() -> Bool {
        activeModel.requestCloseActiveWorkbenchItem()
    }

    func requestCloseActiveSession() -> Bool {
        // Dedicated windows always dismiss instead of becoming welcome.
        false
    }

    func saveAllDocuments() -> Bool {
        var savedAll = true
        for model in scopedSessions where !model.saveAllDocuments() {
            savedAll = false
        }
        return savedAll
    }

    func resetForProjectWindowClose() async {
        await manager.resetDedicatedWindowSession(windowID: windowID)
    }

    func noteWindowBecameKey() {
        manager.noteWindowBecameKey(scope)
    }
}
