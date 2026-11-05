import Foundation
import Testing
@testable import Lithe

struct MacKeymapImportRecognitionTests {
    @Test
    func usesOnlyDeclaredMetadataAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keymap-recognition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/keymap-import/keymap-import-provider.plugin.json")
        let operations = RustKeymapImportOperations(core: RustCoreBridge())
        let first = try operations.planSources(manifest: Data(contentsOf: manifest), providerID: "first")
        let second = try operations.planSources(manifest: Data(contentsOf: manifest), providerID: "second")
        let defaultRoot = root.appendingPathComponent("FirstEditor/User")
        let profile = defaultRoot.appendingPathComponent("profiles/example")
        let unrelated = root.appendingPathComponent("OtherEditor/User")
        for directory in [defaultRoot, profile, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #expect(try MacKeymapImportRecognition.matches(root: defaultRoot, plan: first, userConfigRoot: root))
        #expect(try MacKeymapImportRecognition.matches(root: profile, plan: first, userConfigRoot: root))
        #expect(try !MacKeymapImportRecognition.matches(root: unrelated, plan: first, userConfigRoot: root))
        #expect(try !MacKeymapImportRecognition.matches(root: root, plan: first))
        #expect(try !MacKeymapImportRecognition.matches(root: root, plan: second))
        try Data("unread".utf8).write(to: root.appendingPathComponent("bindings.json"))
        #expect(try MacKeymapImportRecognition.matches(root: root, plan: first))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keymaps"), withIntermediateDirectories: true)
        #expect(try MacKeymapImportRecognition.matches(root: root, plan: second))
        try FileManager.default.removeItem(at: root.appendingPathComponent("bindings.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bindings.json"),
            withDestinationURL: root.appendingPathComponent("keymaps"))
        #expect(throws: (any Error).self) { try MacKeymapImportRecognition.matches(root: root, plan: first) }
    }
}
