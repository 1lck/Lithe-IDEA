import AppKit
import Testing
import WebKit
@testable import Lithe

@Suite("Monaco document session lifetime")
@MainActor
struct MonacoWorkbenchSessionLifetimeTests {
    @Test func crossFileRegistrationPreservesTargetSaveAndCloseBarriers() throws {
        let project = UUID()
        let a = EditorDocument(url: URL(fileURLWithPath: "/fixture/A.swift"), text: "a", modificationDate: nil)
        let b = EditorDocument(url: URL(fileURLWithPath: "/fixture/B.swift"), text: "b", modificationDate: nil)
        let source = MonacoWorkbenchSession.forModel(project, documentID: a.id)
        let target = MonacoWorkbenchSession.forModel(project, documentID: b.id)
        target.register(b)
        let owner = try #require(b.editorSynchronizationOwnerID)
        var drain: ((Result<Void, Error>) -> Void)?
        var held = false, released = false, savedText: String?
        b.synchronizeEditor = { drain = $0 }
        b.holdEditorForClose = { completion in
            held = true
            completion(.success { released = true })
        }
        defer { b.synchronizeEditor = nil; b.holdEditorForClose = nil }
        source.register(a)
        // This is the registration used by both Rename and Code Action payloads.
        source.register(b)
        source.register(b)
        #expect(b.editorSynchronizationOwnerID == owner)
        b.withSynchronizedEditor { result in
            if case .success = result { savedText = b.text }
        }
        #expect(savedText == nil, "Save must wait for B's pending editor input")
        let revision = b.lifecycleState.revision
        b.applyLiveEditorText("b pending input")
        let completeDrain = try #require(drain)
        completeDrain(.success(()))
        #expect(savedText == "b pending input")
        #expect(b.lifecycleState.revision == revision + 1)
        b.holdEditorForClose? { result in
            if case .success(let release) = result { release() }
        }
        #expect(held && released)
        #expect(b.editorSynchronizationOwnerID == owner)
    }

    @Test func movingDocumentBetweenMountsRetainsItsNativeEditor() throws {
        let project = UUID(), document = UUID()
        let session = MonacoWorkbenchSession.forModel(project, documentID: document)
        let firstOwner = UUID(), secondOwner = UUID()
        let first = session.makeContainer(ownerID: firstOwner, isPreview: false)
        let original = try #require(first.subviews.first as? WKWebView)
        let reused = MonacoWorkbenchSession.forModel(project, documentID: document)
        #expect(reused === session)
        let second = reused.makeContainer(ownerID: secondOwner, isPreview: false)
        defer {
            session.detachView(ownerID: firstOwner)
            session.detachView(ownerID: secondOwner)
            original.stopLoading()
        }
        #expect(second.subviews.first === original)
        #expect(first.subviews.isEmpty)
        session.detachView(ownerID: firstOwner)
        #expect(second.subviews.first === original, "Late source teardown must not detach the moved editor")
        #expect(MonacoWorkbenchSession.forModel(project, documentID: UUID()) !== session)
        #expect(MonacoWorkbenchSession.forModel(UUID(), documentID: document) !== session)
    }

    @Test func readOnlyPreviewRejectsRunActionsAtTheNativeBoundary() {
        let main = MonacoWorkbenchSession.forModel(UUID())
        let preview = MonacoWorkbenchSession.forModel(UUID(), documentID: UUID(), previewID: UUID())
        for message in ["javaRunMarkerAction", "format", "rename", "executeCodeAction"] {
            #expect(main.allowsMessage(message))
            #expect(!preview.allowsMessage(message))
        }
        #expect(preview.allowsMessage("hover"))
        #expect(preview.allowsMessage("definition"))
    }

    @Test func independentPreviewKeepsMainDocumentAndSynchronizationOwner() throws {
        let project = UUID(), previewID = UUID()
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/Problems.java"),
                                      text: "class Problems {}", modificationDate: nil)
        let main = MonacoWorkbenchSession.forModel(project, documentID: document.id)
        main.register(document)
        let owner = try #require(document.editorSynchronizationOwnerID)
        defer { document.synchronizeEditor = nil; document.holdEditorForClose = nil }
        var preview: MonacoWorkbenchSession? = MonacoWorkbenchSession.forModel(project,
            documentID: document.id, previewID: previewID)
        weak var released = preview
        #expect(preview !== main)
        #expect(preview?.isReadOnlyPreview == true)
        #expect(MonacoWorkbenchSession.forModel(project, documentID: document.id, previewID: previewID) === preview)
        preview?.register(document)
        #expect(document.editorSynchronizationOwnerID == owner)
        #expect(!document.isReadOnly, "Preview must not make the actual editor document read-only")
        document.applyLiveEditorText("class Problems { int changed; }")
        #expect(document.text.contains("changed"))
        preview = nil
        #expect(released == nil, "Closing a read-only preview must release its session")
        #expect(document.editorSynchronizationOwnerID == owner)
        #expect(MonacoWorkbenchSession.forModel(project, documentID: document.id) === main)
    }

}
