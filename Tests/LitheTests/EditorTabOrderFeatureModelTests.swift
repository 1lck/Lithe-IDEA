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

    @Test
    func movingADocumentTabActivatesItsContent() throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let appModel = AppModel(settings: settings, services: services)
        let firstURL = try #require(URL(string: "lithe-test://documents/First.swift"))
        let secondURL = try #require(URL(string: "lithe-test://documents/Second.swift"))
        appModel.documentFeature.openVirtualDocument(firstURL, text: "first", displayPath: nil)
        appModel.documentFeature.openVirtualDocument(secondURL, text: "second", displayPath: nil)
        let firstDocument = try #require(
            appModel.openDocuments.first(where: { $0.url == firstURL })
        )
        let secondDocument = try #require(
            appModel.openDocuments.first(where: { $0.url == secondURL })
        )
        appModel.selectEditorDocument(secondDocument)

        appModel.moveEditorTab(
            .document(firstDocument.id),
            after: .document(secondDocument.id)
        )

        #expect(appModel.editorTabItems == [
            .document(secondDocument.id),
            .document(firstDocument.id)
        ])
        #expect(appModel.activeDocumentID == firstDocument.id)
        #expect(appModel.activeEditorTerminalSession == nil)
    }
}

private final class EditorTabOrderTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
