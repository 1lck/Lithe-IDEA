import Foundation
import Testing
@testable import Lithe

struct MacKeymapImportSnapshotTests {
    private func plan(_ providerID: String) throws -> KeymapImportSourcePlan {
        let fixture = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/keymap-import/keymap-import-provider.plugin.json")
        return try RustKeymapImportOperations(core: RustCoreBridge()).planSources(
            manifest: Data(contentsOf: fixture), providerID: providerID
        )
    }

    @Test
    func directoryScanCountsEntriesWithUnmatchedExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keymap-names-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("keymaps")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: directory.appendingPathComponent("first.txt"))
        try Data().write(to: directory.appendingPathComponent("second.txt"))
        let original = try plan("second")
        let limits = KeymapImportSourcePlan.Limits(selectors: original.limits.selectors, probes: original.limits.probes,
            files: original.limits.files, fileBytes: original.limits.fileBytes, totalBytes: original.limits.totalBytes,
            chunkBytes: original.limits.chunkBytes, directoryEntries: 1, directoryMatches: original.limits.directoryMatches)
        let bounded = KeymapImportSourcePlan(inputs: original.inputs, recognition: original.recognition, limits: limits)
        #expect(throws: (any Error).self) { try MacKeymapImportSnapshot(root: root, plan: bounded) }
    }

    @Test
    func readsOnlyDeclaredFilesInBoundedChunksAndCloses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keymap-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keymaps"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abcdef".utf8).write(to: root.appendingPathComponent("bindings.json"))
        try Data("xml".utf8).write(to: root.appendingPathComponent("keymaps/custom.xml"))
        try Data("private".utf8).write(to: root.appendingPathComponent("keymaps/secret.txt"))
        let first = try plan("first"), second = try plan("second")
        let snapshot = try MacKeymapImportSnapshot(root: root,
            plan: .init(inputs: first.inputs + second.inputs, recognition: first.recognition + second.recognition, limits: first.limits))
        defer { snapshot.close() }
        #expect(snapshot.files.map(\.path) == ["bindings.json", "keymaps/custom.xml"])
        let file = try #require(snapshot.files.first)
        #expect(file.byteCount == 6)
        #expect(try snapshot.read(fileID: file.id, offset: 1, maximumBytes: 2) == Data("bc".utf8))
        #expect(try snapshot.read(fileID: file.id, offset: 5, maximumBytes: 20) == Data("f".utf8))
        #expect(try snapshot.read(fileID: file.id, offset: 6, maximumBytes: 20).isEmpty)
        #expect(throws: (any Error).self) { try snapshot.read(fileID: file.id, offset: 0, maximumBytes: first.limits.chunkBytes + 1) }
        snapshot.close()
        #expect(throws: (any Error).self) { try snapshot.read(fileID: file.id, offset: 0, maximumBytes: 1) }
    }

    @Test
    func rejectsSymlinksAndDetectsReplacementOfASnapshottedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keymap-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keymaps"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("bindings.json")
        try Data("before".utf8).write(to: target)
        let link = root.appendingPathComponent("keymaps/link.xml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try MacKeymapImportSnapshot(root: root, plan: plan("second"))
        }
        let snapshot = try MacKeymapImportSnapshot(root: root, plan: plan("first"))
        defer { snapshot.close() }
        let id = try #require(snapshot.files.first?.id)
        try snapshot.validate()
        let originalDigest = try snapshot.contentDigest()
        let same = try MacKeymapImportSnapshot(root: root, plan: plan("first"))
        #expect(try same.contentDigest() == originalDigest)
        same.close()
        try Data("after!".utf8).write(to: target, options: .atomic)
        #expect(throws: (any Error).self) { try snapshot.read(fileID: id, offset: 0, maximumBytes: 6) }
        #expect(throws: (any Error).self) { try snapshot.validate() }
        let replacement = try MacKeymapImportSnapshot(root: root, plan: plan("first"))
        defer { replacement.close() }
        #expect(try replacement.contentDigest() != originalDigest)
    }
}
