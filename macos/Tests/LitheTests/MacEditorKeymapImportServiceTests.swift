import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct MacEditorKeymapImportServiceTests {
    private let provider = MacPluginBackendSessions.KeymapProvider(pluginID: "fixture.plugin", id: "first", displayName: "Fixture")

    private func source() -> EditorSettingsImportSource {
        EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture"), title: "Fixture", revision: "appearance",
            values: ["tabSize": "2"], warnings: [])
    }

    @Test
    func unmatchedSourceKeepsOtherSettingsWithoutStartingAProvider() async throws {
        let service = MacEditorKeymapImportService(find: { _ in [] }, importProvider: { _, _ in
            Issue.record("An unmatched source must not start a provider")
            throw EditorSettingsImportError.invalid
        }, operations: RustKeymapImportOperations(core: RustCoreBridge()))
        #expect(try await service.importing(source()) == source())
    }

    @Test
    func mergesValidatedProviderBindingsAndSourceRevision() async throws {
        let response: ToolingJSONValue = .object(["response": .object(["result": .object(["bindings": .array([
            .object(["commandID": .string("toggle-breakpoint"), "keys": .array([
                .object(["key": .string("f9"), "modifiers": .array([])])
            ])])
        ])])])])
        let service = MacEditorKeymapImportService(find: { _ in [provider] }, importProvider: { _, _ in
            .init(response: response, sourceDigest: "digest", sourceFileCount: 0)
        }, operations: RustKeymapImportOperations(core: RustCoreBridge()))
        let result = try await service.importing(source())
        let keymap = try #require(result.values["keymap"].flatMap(EditorImportKeymap.decode))
        #expect(keymap.commands["toggle-breakpoint"] == [.keyPress(key: "f9", modifiers: [])])
        #expect(result.values["tabSize"] == "2")
        #expect(result.revision != "appearance")
        #expect(result.defaultFields.contains("keymap"))
    }

    @Test
    func rejectsAmbiguousProvidersAndUnsupportedNativeKeys() async throws {
        let other = MacPluginBackendSessions.KeymapProvider(pluginID: "other.plugin", id: "second", displayName: "Other")
        let ambiguous = MacEditorKeymapImportService(find: { _ in [provider, other] }, importProvider: { _, _ in
            Issue.record("Ambiguous providers must not be started")
            throw EditorSettingsImportError.invalid
        }, operations: RustKeymapImportOperations(core: RustCoreBridge()))
        await #expect(throws: EditorSettingsImportError.self) { try await ambiguous.importing(source()) }
        let response: ToolingJSONValue = .object(["response": .object(["result": .object(["bindings": .array([
            .object(["commandID": .string("find-next"), "keys": .array([
                .object(["key": .string("f24"), "modifiers": .array([])])
            ])])
        ])])])])
        let unsupported = MacEditorKeymapImportService(find: { _ in [provider] }, importProvider: { _, _ in
            .init(response: response, sourceDigest: "digest", sourceFileCount: 1)
        }, operations: RustKeymapImportOperations(core: RustCoreBridge()))
        await #expect(throws: (any Error).self) { try await unsupported.importing(source()) }
    }
}
