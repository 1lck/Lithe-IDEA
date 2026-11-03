import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct MacKeymapImportSnapshotsTests {
    @Test
    func hostServiceRequiresGrantAndRevokesSnapshotWhenSessionEnds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keymap-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("bindings".utf8).write(to: root.appendingPathComponent("bindings.json"))
        let fixture = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/keymap-import-provider.plugin.json")
        let plan = try RustKeymapImportOperations(core: RustCoreBridge()).planSources(
            manifest: Data(contentsOf: fixture), providerID: "first"
        )
        let service = MacKeymapImportHostService()
        let dispatcher = PluginHostServiceDispatcher(contexts: PluginWorkspaceContexts())
        dispatcher.register(service)
        let method = "lithe/host/keymapImport/readChunk"
        let listMethod = "lithe/host/keymapImport/listInputs"
        let session = dispatcher.beginSession(pluginID: "editor", hostServices: [method, listMethod])
        let snapshot = try MacKeymapImportSnapshot(root: root, plan: plan)
        let token = service.snapshots.insert(snapshot, pluginID: "editor", sessionID: session, providerID: "first")
        let file = try #require(snapshot.files.first)
        let list = PluginHostRequest(id: "list", method: listMethod, service: "keymapImport", params:
            .object(["snapshotID": .string(token), "providerID": .string("first")]))
        #expect(try await dispatcher.dispatch(list, pluginID: "editor").get() == .object(["files": .array([
            .object(["id": .string(file.id), "path": .string("bindings.json"), "byteCount": .integer(8)])
        ])]))
        let params: ToolingJSONValue = .object(["snapshotID": .string(token), "providerID": .string("first"),
            "fileID": .string(file.id), "offset": .integer(0), "maximumBytes": .integer(8)])
        let request = PluginHostRequest(id: "1", method: method, service: "keymapImport", params: params)
        #expect(try await dispatcher.dispatch(request, pluginID: "editor").get() == .object(["data": .string("YmluZGluZ3M=")]))
        _ = dispatcher.beginSession(pluginID: "other", hostServices: [method])
        if case .success = await dispatcher.dispatch(request, pluginID: "other") {
            Issue.record("Another plugin must not read this snapshot")
        }
        dispatcher.endSession(pluginID: "editor")
        #expect(throws: (any Error).self) { try snapshot.read(fileID: file.id, offset: 0, maximumBytes: 1) }
        dispatcher.endSession(pluginID: "other")
    }
    @Test
    func snapshotsAreBoundToTheOwningSessionAndRevoked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keymap-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("bindings".utf8).write(to: root.appendingPathComponent("bindings.json"))
        let fixture = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/keymap-import-provider.plugin.json")
        let plan = try RustKeymapImportOperations(core: RustCoreBridge()).planSources(
            manifest: Data(contentsOf: fixture), providerID: "first"
        )
        let registry = MacKeymapImportSnapshots()
        let snapshot = try MacKeymapImportSnapshot(root: root, plan: plan)
        let token = registry.insert(snapshot, pluginID: "editor", sessionID: "session-1", providerID: "first")
        #expect(try registry.snapshot(token, pluginID: "editor", sessionID: "session-1", providerID: "first") === snapshot)
        #expect(throws: (any Error).self) { try registry.snapshot(token, pluginID: "other", sessionID: "session-1", providerID: "first") }
        #expect(throws: (any Error).self) { try registry.snapshot(token, pluginID: "editor", sessionID: "session-2", providerID: "first") }
        #expect(throws: (any Error).self) { try registry.snapshot(token, pluginID: "editor", sessionID: "session-1", providerID: "second") }
        registry.endSession(pluginID: "other", sessionID: "session-1")
        #expect(try registry.snapshot(token, pluginID: "editor", sessionID: "session-1", providerID: "first") === snapshot)
        let replacement = try MacKeymapImportSnapshot(root: root, plan: plan)
        let replacementToken = registry.insert(replacement, pluginID: "editor", sessionID: "session-1", providerID: "first")
        #expect(throws: (any Error).self) { try registry.snapshot(token, pluginID: "editor", sessionID: "session-1", providerID: "first") }
        let originalFileID = try #require(snapshot.files.first?.id)
        #expect(throws: (any Error).self) { try snapshot.read(fileID: originalFileID, offset: 0, maximumBytes: 1) }
        registry.endSession(pluginID: "editor", sessionID: "session-1")
        #expect(throws: (any Error).self) { try registry.snapshot(replacementToken, pluginID: "editor", sessionID: "session-1", providerID: "first") }
        let fileID = try #require(replacement.files.first?.id)
        #expect(throws: (any Error).self) { try replacement.read(fileID: fileID, offset: 0, maximumBytes: 1) }
    }
}
