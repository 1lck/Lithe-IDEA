import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

struct RustKeymapImportOperationsTests {
    @Test
    func convertsOnlyKeysTheNativeHostCanRegister() throws {
        let binding = KeymapImportBinding(commandID: "toggle-breakpoint", keys: [
            .init(key: "f9", modifiers: []), .init(key: "backspace", modifiers: [.alt, .meta])
        ])
        #expect(try binding.nativeBindings() == [.keyPress(key: "f9", modifiers: []),
            .keyPress(key: "delete", modifiers: [.option, .command])])
        for unsupported in ["delete", "escape", "f24"] {
            let bad = KeymapImportBinding(commandID: "find-next", keys: [.init(key: unsupported, modifiers: [])])
            #expect(throws: (any Error).self) { try bad.nativeBindings() }
        }
    }
    @Test
    func plansDefaultDisplacementWithoutOverwritingCustomBindings() throws {
        let operations = RustKeymapImportOperations(core: RustCoreBridge())
        let f9 = KeymapImportBinding.Key(key: "f9", modifiers: [])
        let incoming = [KeymapImportBinding(commandID: "toggle-breakpoint", keys: [f9])]
        let base = [KeymapImportCurrent(commandID: "debug-resume", customized: false, keys: [f9]),
                    KeymapImportCurrent(commandID: "toggle-breakpoint", customized: false, keys: [])]
        let plan = try operations.planBindings(current: base, incoming: incoming)
        #expect(plan.displaced == [KeymapImportBinding(commandID: "debug-resume", keys: [f9])])
        #expect(plan.conflicts.isEmpty)
        let custom = [KeymapImportCurrent(commandID: "debug-resume", customized: true, keys: [f9]), base[1]]
        let blocked = try operations.planBindings(current: custom, incoming: incoming)
        #expect(blocked.displaced.isEmpty)
        #expect(blocked.conflicts.first?.ownerID == "debug-resume")
    }

    @Test
    func plansOnlyTheSelectedProvidersDeclaredSources() throws {
        let manifest = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/keymap-import-provider.plugin.json")
        let operations = RustKeymapImportOperations(core: RustCoreBridge())
        let plan = try operations.planSources(manifest: Data(contentsOf: manifest), providerID: "second")
        #expect(plan.inputs == [
            .init(kind: .file, path: "options/map.xml", fileExtension: nil),
            .init(kind: .directory, path: "keymaps", fileExtension: "xml")
        ])
        #expect(plan.limits.fileBytes == 1_048_576)
        #expect(plan.recognition == [.directory(path: "keymaps")])
        #expect(plan.limits.chunkBytes == 131_072)
        #expect(throws: (any Error).self) {
            try operations.planSources(manifest: Data(contentsOf: manifest), providerID: "unknown")
        }
    }

    @Test
    func validatesAnUntrustedProviderReplyBeforeNativeUse() throws {
        let operations = RustKeymapImportOperations(core: RustCoreBridge())
        let reply: ToolingJSONValue = .object(["bindings": .array([
            .object(["commandID": .string("find-next"), "keys": .array([
                .object(["key": .string("g"), "modifiers": .array([.string("meta"), .string("alt")])])
            ])])
        ])])
        let bindings = try operations.decodeImport(commandIDs: ["find-next"], reply: reply)
        #expect(bindings.count == 1)
        #expect(bindings[0].commandID == "find-next")
        #expect(bindings[0].keys[0].modifiers == [.alt, .meta])
        #expect(throws: (any Error).self) {
            try operations.decodeImport(commandIDs: ["other"], reply: reply)
        }
    }
}
