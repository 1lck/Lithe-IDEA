import Combine
import Foundation

/// Owns where live terminal sessions are presented without taking ownership
/// of their PTY or native surface lifecycle.
@MainActor
final class TerminalPlacementFeatureModel: ObservableObject {
    @Published private(set) var toolSessionIDs: [UUID] = []
    @Published private(set) var editorSessionIDs: [UUID] = []
    @Published private(set) var activeEditorSessionID: UUID?

    func registerSession(_ sessionID: UUID) {
        guard !contains(sessionID) else { return }
        toolSessionIDs.append(sessionID)
    }

    func moveToTool(_ sessionID: UUID) {
        moveToTool(sessionID, relativeTo: nil, insertAfter: false)
    }

    func moveToTool(_ sessionID: UUID, before targetSessionID: UUID) {
        guard sessionID != targetSessionID else { return }
        moveToTool(sessionID, relativeTo: targetSessionID, insertAfter: false)
    }

    func moveToTool(_ sessionID: UUID, after targetSessionID: UUID) {
        guard sessionID != targetSessionID else { return }
        moveToTool(sessionID, relativeTo: targetSessionID, insertAfter: true)
    }

    func moveToEditor(_ sessionID: UUID) {
        moveToEditor(sessionID, relativeTo: nil, insertAfter: false)
    }

    func moveToEditor(_ sessionID: UUID, before targetSessionID: UUID) {
        guard sessionID != targetSessionID else { return }
        moveToEditor(sessionID, relativeTo: targetSessionID, insertAfter: false)
    }

    func moveToEditor(_ sessionID: UUID, after targetSessionID: UUID) {
        guard sessionID != targetSessionID else { return }
        moveToEditor(sessionID, relativeTo: targetSessionID, insertAfter: true)
    }

    func activateEditorSession(_ sessionID: UUID) {
        guard editorSessionIDs.contains(sessionID) else { return }
        activeEditorSessionID = sessionID
    }

    func activateDocument() {
        activeEditorSessionID = nil
    }

    func removeSession(_ sessionID: UUID) {
        toolSessionIDs.removeAll { $0 == sessionID }
        editorSessionIDs.removeAll { $0 == sessionID }
        if activeEditorSessionID == sessionID {
            activeEditorSessionID = editorSessionIDs.last
        }
    }

    func reset() {
        toolSessionIDs = []
        editorSessionIDs = []
        activeEditorSessionID = nil
    }

    private func contains(_ sessionID: UUID) -> Bool {
        toolSessionIDs.contains(sessionID) || editorSessionIDs.contains(sessionID)
    }

    private func moveToTool(
        _ sessionID: UUID,
        relativeTo targetSessionID: UUID?,
        insertAfter: Bool
    ) {
        guard contains(sessionID) else { return }
        editorSessionIDs.removeAll { $0 == sessionID }
        toolSessionIDs.removeAll { $0 == sessionID }
        insert(
            sessionID,
            into: &toolSessionIDs,
            relativeTo: targetSessionID,
            insertAfter: insertAfter
        )
        if activeEditorSessionID == sessionID {
            activeEditorSessionID = editorSessionIDs.last
        }
    }

    private func moveToEditor(
        _ sessionID: UUID,
        relativeTo targetSessionID: UUID?,
        insertAfter: Bool
    ) {
        guard contains(sessionID) else { return }
        toolSessionIDs.removeAll { $0 == sessionID }
        editorSessionIDs.removeAll { $0 == sessionID }
        insert(
            sessionID,
            into: &editorSessionIDs,
            relativeTo: targetSessionID,
            insertAfter: insertAfter
        )
        activeEditorSessionID = sessionID
    }

    private func insert(
        _ sessionID: UUID,
        into sessionIDs: inout [UUID],
        relativeTo targetSessionID: UUID?,
        insertAfter: Bool
    ) {
        guard let targetSessionID,
              let targetIndex = sessionIDs.firstIndex(of: targetSessionID) else {
            sessionIDs.append(sessionID)
            return
        }
        sessionIDs.insert(sessionID, at: targetIndex + (insertAfter ? 1 : 0))
    }
}
