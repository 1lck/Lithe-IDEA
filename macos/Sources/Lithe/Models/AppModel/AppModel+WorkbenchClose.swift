import Foundation

extension AppModel {
    /// Closes the content currently occupying the editor surface before the
    /// native window close command is allowed to reach AppKit.
    @discardableResult
    func requestCloseActiveWorkbenchItem() -> Bool {
        if standaloneFileURL != nil {
            closeStandaloneFile()
            return true
        }
        if pendingCloseDocument != nil || pendingTerminalCloseSessionID != nil {
            return true
        }
        if isImplementationChooserVisible {
            closeLanguageNavigationResults()
            return true
        }
        if selectedSidebar == .database {
            selectedSidebar = .project
            return true
        }
        if branchComparison != nil {
            closeBranchComparison()
            return true
        }
        if selectedGitCommitDiffContext != nil {
            closeGitCommitDiff()
            return true
        }
        if selectedChange != nil {
            selectedChange = nil
            return true
        }
        if let session = activeEditorTerminalSession {
            requestCloseTerminalSession(session)
            return true
        }
        if let document = activeDocument {
            requestCloseDocument(document)
            return true
        }
        guard let item = editorTabItems.last else { return false }
        switch item {
        case .document(let documentID):
            guard let document = openDocuments.first(where: { $0.id == documentID }) else {
                editorTabOrderFeature.remove(item)
                return true
            }
            requestCloseDocument(document)
        case .terminal(let sessionID):
            guard let session = terminalSessions.first(where: { $0.id == sessionID }) else {
                editorTabOrderFeature.remove(item)
                terminalPlacementFeature.removeSession(sessionID)
                return true
            }
            requestCloseTerminalSession(session)
        case .media(let mediaID):
            if let media = openMediaDocuments.first(where: { $0.id == mediaID }) {
                closeMediaDocument(media)
            } else {
                editorTabOrderFeature.remove(item)
            }
        }
        return true
    }
}
