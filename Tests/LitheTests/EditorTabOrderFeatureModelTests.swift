import Foundation
import Testing
@testable import Lithe

@Suite("Editor tab order")
@MainActor
struct EditorTabOrderFeatureModelTests {
    @Test
    func mixesDocumentsAndTerminalsInOneOrder() {
        let model = EditorTabOrderFeatureModel()
        let firstDocument = UUID()
        let secondDocument = UUID()
        let terminal = UUID()
        model.reconcileDocuments(orderedIDs: [firstDocument, secondDocument])

        model.move(.terminal(terminal), before: .document(secondDocument))

        #expect(model.items == [
            .document(firstDocument),
            .terminal(terminal),
            .document(secondDocument)
        ])
    }

    @Test
    func documentReconciliationPreservesTerminalSlots() {
        let model = EditorTabOrderFeatureModel()
        let firstDocument = UUID()
        let secondDocument = UUID()
        let terminal = UUID()
        model.reconcileDocuments(orderedIDs: [firstDocument, secondDocument])
        model.move(.terminal(terminal), before: .document(secondDocument))

        model.reconcileDocuments(orderedIDs: [secondDocument, firstDocument])

        #expect(model.items == [
            .document(secondDocument),
            .terminal(terminal),
            .document(firstDocument)
        ])
    }

    @Test
    func removingTerminalsLeavesDocumentOrderUntouched() {
        let model = EditorTabOrderFeatureModel()
        let firstDocument = UUID()
        let secondDocument = UUID()
        model.reconcileDocuments(orderedIDs: [firstDocument, secondDocument])
        model.move(.terminal(UUID()), before: .document(secondDocument))

        model.removeAllTerminals()

        #expect(model.items == [.document(firstDocument), .document(secondDocument)])
    }
}
