import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

struct WorkspaceDirectoryMarkStoreTests {
    @Test
    func directoryMarksRoundTripWithoutWritingIntoTheWorkspace() throws {
        let preferences = DirectoryMarkKeyValueStore()
        let store = WorkspaceDirectoryMarkStore(store: preferences)
        let workspaceURL = URL(fileURLWithPath: "/projects/example")
        let marks: [String: WorkspaceDirectoryMark] = [
            "Sources": .sources,
            "assets": .resources,
            "generated": .plain
        ]

        try store.saveDirectoryMarks(marks, for: workspaceURL)

        #expect(try store.loadDirectoryMarks(for: workspaceURL) == marks)
        #expect(
            try store.loadDirectoryMarks(for: URL(fileURLWithPath: "/projects/other")).isEmpty
        )
    }
    @Test
    func indexingSettingsPreserveManualMarksAndProjectIsolation() throws {
        let store = WorkspaceDirectoryMarkStore(store: DirectoryMarkKeyValueStore())
        let root = URL(fileURLWithPath: "/projects/example")
        #expect(try store.loadIndexingSettings(for: root).gitIgnoreEnabled)
        try store.saveDirectoryMarks(["vendor": .excluded], for: root)
        var settings = WorkspaceIndexingSettings()
        settings.gitIgnoreEnabled = false
        settings.includedDirectories = ["generated/examples"]
        settings.previousRoles = ["vendor": .sources]
        let similarlyNamedRoot = URL(fileURLWithPath: "/projects/example.indexing")
        try store.saveDirectoryMarks(["source": .sources], for: similarlyNamedRoot)
        try store.saveIndexingSettings(settings, for: root)
        #expect(try store.loadDirectoryMarks(for: similarlyNamedRoot) == ["source": .sources])
        #expect(try store.loadIndexingSettings(for: root) == settings)
        #expect(try store.loadDirectoryMarks(for: root) == ["vendor": .excluded])
        #expect(try store.loadIndexingSettings(for: URL(fileURLWithPath: "/projects/other")).includedDirectories.isEmpty)
    }

}

private final class DirectoryMarkKeyValueStore: KeyValueStore {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
