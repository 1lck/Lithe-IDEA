import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Lithe

@Suite("Editor tab layout")
struct EditorTabLayoutTests {
    @Test
    func flowLayoutWrapsByIntrinsicWidth() {
        let rows = EditorTabFlowPlanner.rows(
            for: [
                CGSize(width: 180, height: 30),
                CGSize(width: 220, height: 30),
                CGSize(width: 160, height: 30)
            ],
            availableWidth: 420,
            horizontalSpacing: 4,
            minimumItemWidth: 154
        )

        #expect(rows.count == 2)
        #expect(rows[0].items.map(\.index) == [0, 1])
        #expect(rows[1].items.map(\.index) == [2])
        #expect(rows[0].width == 404)
        #expect(rows[1].width == 160)
        #expect(EditorTabFlowPlanner.height(for: rows, verticalSpacing: 2) == 62)
    }

    @Test
    func flowLayoutClampsLongTabToAvailableWidth() {
        let rows = EditorTabFlowPlanner.rows(
            for: [CGSize(width: 600, height: 30)],
            availableWidth: 420,
            horizontalSpacing: 4,
            minimumItemWidth: 154
        )

        #expect(rows.count == 1)
        #expect(rows[0].items[0].width == 420)
        #expect(rows[0].width == 420)
    }

    @Test
    func flowLayoutDoesNotOverflowAWindowNarrowerThanMinimumTabWidth() {
        let rows = EditorTabFlowPlanner.rows(
            for: [CGSize(width: 180, height: 30)],
            availableWidth: 100,
            horizontalSpacing: 4,
            minimumItemWidth: 154
        )

        #expect(rows[0].items[0].width == 100)
        #expect(rows[0].width == 100)
    }

    @Test
    func tabDragPayloadOffersThePrivateReorderType() {
        let provider = EditorTabDragPayload.provider(for: UUID())

        #expect(provider.registeredTypeIdentifiers.contains(EditorTabDragPayload.type.identifier))
        #expect(provider.registeredTypeIdentifiers.contains(UTType.utf8PlainText.identifier))
    }

    @Test
    func cancelledDragStateClearsSourceAndDropTarget() {
        var state = EditorTabDragState.idle
        let documentID = UUID()
        state.begin(documentID: documentID)
        state.updateTarget(EditorTabDropTarget(documentID: UUID(), side: .after))

        state.finish()

        #expect(state == .idle)
    }

    @Test
    func staleDropExitCannotClearTheCurrentTargetAfterFlowReordering() {
        var state = EditorTabDragState.idle
        let sourceID = UUID()
        let firstTargetID = UUID()
        let currentTargetID = UUID()

        state.begin(documentID: sourceID)
        let sessionID = state.sessionID
        state.updateTarget(EditorTabDropTarget(documentID: firstTargetID, side: .after))
        let staleRevision = state.dropTargetRevision
        state.updateTarget(EditorTabDropTarget(documentID: currentTargetID, side: .after))
        let currentRevision = state.dropTargetRevision

        let staleClearSucceeded = state.clearTarget(
            documentID: firstTargetID,
            sessionID: sessionID,
            revision: staleRevision
        )
        #expect(!staleClearSucceeded)
        #expect(state.dropTarget?.documentID == currentTargetID)
        let currentClearSucceeded = state.clearTarget(
            documentID: currentTargetID,
            sessionID: sessionID,
            revision: currentRevision
        )
        #expect(currentClearSucceeded)
        #expect(state.draggedDocumentID == sourceID)

        state.finish()
        #expect(state == .idle)
    }
}
