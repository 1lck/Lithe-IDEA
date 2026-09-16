import Foundation
import Testing
@testable import Lithe

@MainActor
@Suite("Monaco asynchronous document identity")
struct MonacoDocumentContextTests {
    private let root = URL(fileURLWithPath: "/in-memory/monaco-context")

    @Test(arguments: ["rename", "rename-back", "close", "reopen", "workspace", "edit"])
    func lateResponseCannotUseChangedDocument(change: String) {
        let url = root.appendingPathComponent("Probe.java")
        let document = EditorDocument(url: url, text: "class Probe {}", modificationDate: nil)
        let context = MonacoDocumentContext(document: document, revision: 7, workspaceURL: root)
        var documents = [document]
        var workspaceURL = root
        var revision = 7
        // The callback retains the original document just as an LSP completion
        // does. Retention alone must not keep it eligible for applying a result.
        let accept = { context.matches(document: document, revision: revision,
            documents: documents, workspaceURL: workspaceURL) }
        #expect(accept())
        switch change {
        case "rename", "rename-back":
            document.relocate(to: root.appendingPathComponent("Other.java"))
            if change == "rename-back" { document.relocate(to: url) }
        case "close": documents.removeAll()
        case "reopen": documents = [EditorDocument(url: url, text: document.text, modificationDate: nil)]
        case "workspace": workspaceURL = root.appendingPathComponent("other-workspace")
        case "edit":
            document.applyLiveEditorText("class Edited {}")
            revision += 1
        default: Issue.record("Unknown change")
        }
        #expect(!accept())
    }

    @Test func commandMayFollowItsOwnWorkspaceEditButNotAMoveOrClose() {
        let document = EditorDocument(url: root.appendingPathComponent("Probe.java"),
            text: "class Probe {}", modificationDate: nil)
        let context = MonacoDocumentContext(document: document, revision: 0, workspaceURL: root)
        document.applyLiveEditorText("class Fixed {}")
        #expect(context.matchesIdentity(document: document, documents: [document], workspaceURL: root))
        #expect(!context.matches(document: document, revision: 1, documents: [document], workspaceURL: root))
        #expect(!context.matchesIdentity(document: document, documents: [], workspaceURL: root))
        document.relocate(to: root.appendingPathComponent("Fixed.java"))
        #expect(!context.matchesIdentity(document: document, documents: [document], workspaceURL: root))
    }

    @Test func sameLocationRefreshDoesNotInvalidateRequests() {
        let document = EditorDocument(url: root.appendingPathComponent("Probe.java"), text: "", modificationDate: nil)
        let context = MonacoDocumentContext(document: document, revision: 0, workspaceURL: root)
        document.relocate(to: document.url)
        #expect(context.matches(document: document, revision: 0, documents: [document], workspaceURL: root))
    }
}
