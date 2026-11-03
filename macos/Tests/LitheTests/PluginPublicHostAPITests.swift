import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@MainActor
struct PluginPublicHostAPITests {
    @Test
    func dispatchReadsDirtySelectionsEditsAndRejectsAnOldVersion() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let contexts = PluginWorkspaceContexts()
        let context = contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
        let document = EditorDocument(url: fixture.url("sample.txt"), text: "hello 😀", modificationDate: nil)
        document.text = "dirty 😀"
        let surface = Surface()
        document.editorSurface = surface
        fixture.window.hostDocumentService = EditorDocumentService(windowID: fixture.windowID,
            workspaceURL: { PluginHostFixture.workspaceURL }, documents: { [document] }, activeDocumentID: { document.id }, languageIdentifier: { _ in nil })
        let dispatcher = PluginHostServiceDispatcher(contexts: contexts)
        dispatcher.register(PluginDocumentHostService(contexts: contexts))
        dispatcher.beginSession(pluginID: "plugin", hostServices: ["lithe/host/documents/getSnapshot", "lithe/host/editor/getSelections", "lithe/host/editor/applyEdits"])
        defer { dispatcher.endSession(pluginID: "plugin") }
        let base: [String: ToolingJSONValue] = ["context": reference(context), "documentID": .string(document.id.uuidString)]
        let snapshot = try await dispatcher.dispatch(request("documents/getSnapshot", base), pluginID: "plugin").get()
        guard case .object(let object) = snapshot else { Issue.record("snapshot missing"); return }
        #expect(object["text"] == .string("dirty 😀"))
        let selected = try await dispatcher.dispatch(request("editor/getSelections", base), pluginID: "plugin").get()
        guard case .object(let selections) = selected else { Issue.record("selections missing"); return }
        #expect(selections["version"] == .integer(Int(document.contentVersion)))
        var edit = base
        edit["expectedVersion"] = .integer(Int(document.contentVersion))
        edit["edits"] = .array([.object(["range": .object([
            "start": .object(["line": .integer(1), "column": .integer(1)]),
            "end": .object(["line": .integer(1), "column": .integer(6)]),
        ]), "text": .string("DONE")])])
        _ = try await dispatcher.dispatch(request("editor/applyEdits", edit), pluginID: "plugin").get()
        #expect(document.text == "DONE 😀")
        let stale = await dispatcher.dispatch(request("editor/applyEdits", edit), pluginID: "plugin")
        #expect(code(stale) == "plugin.host.versionConflict")
        #expect(surface.before == ["dirty 😀"])
        let previous = surface.before.popLast()
        document.text = try #require(previous)
        #expect(document.text == "dirty 😀")
        contexts.close(owner: fixture.window)
        #expect(code(await dispatcher.dispatch(request("documents/getSnapshot", base), pluginID: "plugin")) == "plugin.host.contextExpired")
    }

    @Test
    func metadataPermissionNeverGrantsFileOrEditorMethods() async {
        let dispatcher = PluginHostServiceDispatcher(contexts: PluginWorkspaceContexts())
        dispatcher.register(PluginDocumentHostService(contexts: dispatcher.contexts))
        dispatcher.beginSession(pluginID: "plugin", hostServices: ["workspace", "editor"])
        defer { dispatcher.endSession(pluginID: "plugin") }
        #expect(code(await dispatcher.dispatch(request("workspace/readFile", [:]), pluginID: "plugin")) == "plugin.host.permissionDenied")
        #expect(code(await dispatcher.dispatch(request("editor/applyEdits", [:]), pluginID: "plugin")) == "plugin.host.permissionDenied")
        #expect(dispatcher.supportedGrants(["lithe/host/editor/applyEdits", "lithe/host/editor/missing"]) == ["lithe/host/editor/applyEdits"])
    }

    @Test
    func closingContextCancelsAnInflightRequestExactlyOnce() async throws {
        let contexts = PluginWorkspaceContexts()
        let window = NSObject()
        let context = contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/fixture/workspace"), remote: nil)
        let dispatcher = PluginHostServiceDispatcher(contexts: contexts)
        let handler = HeldHandler()
        dispatcher.register(handler)
        dispatcher.beginSession(pluginID: "plugin", hostServices: ["lithe/host/test/wait"])
        defer { handler.release.open(); dispatcher.endSession(pluginID: "plugin") }
        let answered = TestGate()
        var answers: [Result<ToolingJSONValue, PluginHostRequestFailure>] = []
        dispatcher.handle(request("test/wait", ["context": reference(context)]), pluginID: "plugin") {
            answers.append($0); answered.open()
        }
        try #require(await handler.started.waitUntilOpen())
        contexts.close(owner: window)
        try #require(await answered.waitUntilOpen())
        try #require(await handler.finished.waitUntilOpen())
        #expect(answers.count == 1)
        #expect(code(answers[0]) == "plugin.host.contextExpired")
    }

    @Test
    func anOldSessionCannotCancelOrAnswerForItsReplacement() async throws {
        let dispatcher = PluginHostServiceDispatcher(contexts: PluginWorkspaceContexts())
        let handler = HeldHandler()
        dispatcher.register(handler)
        let old = dispatcher.beginSession(pluginID: "plugin", hostServices: ["lithe/host/test/wait"])
        let current = dispatcher.beginSession(pluginID: "plugin", hostServices: ["lithe/host/test/wait"])
        defer { handler.release.open(); dispatcher.endSession(pluginID: "plugin") }
        let answered = TestGate()
        var count = 0
        dispatcher.handle(request("test/wait", [:]), pluginID: "plugin", sessionID: current) { _ in count += 1; answered.open() }
        try #require(await handler.started.waitUntilOpen())
        dispatcher.cancel(hostRequestID: "test-request", pluginID: "plugin", sessionID: old)
        #expect(!handler.finished.isOpen)
        handler.release.open()
        try #require(await answered.waitUntilOpen())
        #expect(count == 1)
        dispatcher.handle(request("test/wait", [:]), pluginID: "plugin", sessionID: old) { _ in count += 1 }
        #expect(count == 1)
    }

    @Test
    func previewExplicitlyChangesAnExistingEditorsMode() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("page.html")
        fixture.window.openBuffers[fixture.path("page.html")] = true
        let preview = PluginHostPreviewService(editor: fixture.editor, directory: fixture.directory)
        let result = try await preview.openHTML(.init(context: fixture.context(), resource: fixture.resource("page.html")))
        #expect(result.presentation == .editorAndPreview)
        #expect(fixture.window.htmlPreviewOnly[fixture.path("page.html")] == false)
        _ = try await preview.openHTML(.init(context: fixture.context(), resource: fixture.resource("page.html"), presentation: .previewOnly))
        #expect(fixture.window.htmlPreviewOnly[fixture.path("page.html")] == true)
        #expect(fixture.window.diskLoads.isEmpty)
    }

    private func reference(_ context: PluginWorkspaceContext) -> ToolingJSONValue {
        .object(["contextID": .string(context.contextID), "generation": .integer(context.generation)])
    }
    private func request(_ method: String, _ params: [String: ToolingJSONValue]) -> PluginHostRequest {
        PluginHostRequest(id: "test-request", method: "lithe/host/" + method,
                          service: String(method.split(separator: "/").first!), params: .object(params))
    }
    private func code(_ result: Result<ToolingJSONValue, PluginHostRequestFailure>) -> String? {
        if case .failure(let error) = result { return error.code }; return nil
    }

    private final class Surface: EditorDocumentSurface {
        var before: [String] = []
        func readSelections(of document: EditorDocument) async throws -> EditorSurfaceSelections {
            EditorSurfaceSelections(selections: [.init(anchor: .init(line: 1, column: 1), active: .init(line: 1, column: 6))], version: document.contentVersion)
        }
        func apply(_ request: EditorSurfaceEditRequest, to document: EditorDocument) async throws -> UInt64 {
            before.append(document.text)
            document.text = EditorTextEditPlanner.apply(request.edits, to: document.text)
            return document.contentVersion
        }
    }

    private final class HeldHandler: PluginHostServiceHandling {
        let service = "test"
        let methods: Set<String> = ["lithe/host/test/wait"]
        let started = TestGate(), release = TestGate(), finished = TestGate()
        func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
            defer { finished.open() }
            started.open()
            _ = await release.waitUntilOpen()
            return .success(.null)
        }
    }
}
