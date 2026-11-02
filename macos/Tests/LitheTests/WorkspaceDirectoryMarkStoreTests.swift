import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

struct WorkspaceDirectoryMarkStoreTests {
    @Test
    func noticeDismissalReadsLegacyPreferencesAndPersistsPerProject() throws {
        let preferences = DirectoryMarkKeyValueStore()
        let store = WorkspaceDirectoryMarkStore(store: preferences)
        let root = URL(fileURLWithPath: "/projects/legacy")
        preferences.set(Data(#"{"gitIgnoreEnabled":false,"includedDirectories":["cache"],"previousRoles":{}}"#.utf8),
                        forKey: "lithe.workspace-indexing." + root.path)
        var settings = try store.loadIndexingSettings(for: root)
        #expect(settings.ignoredDirectoryNoticeDismissed == nil)
        settings.ignoredDirectoryNoticeDismissed = true
        try store.saveIndexingSettings(settings, for: root)
        #expect(try store.loadIndexingSettings(for: root) == settings)
        #expect(try store.loadIndexingSettings(for: URL(fileURLWithPath: "/projects/other")).ignoredDirectoryNoticeDismissed != true)
    }
    @Test(arguments: ["broken", "null", "{}", "{\"gitIgnoreEnabled\":null,\"includedDirectories\":[]}", "{\"gitIgnoreEnabled\":true,\"includedDirectories\":[1]}"])
    func invalidIndexingSettingsAreClassifiedAndPreserved(_ raw: String) throws {
        let preferences = DirectoryMarkKeyValueStore()
        let root = URL(fileURLWithPath: "/projects/invalid-indexing")
        let key = "lithe.workspace-indexing." + root.path
        let data = Data(raw.utf8)
        preferences.set(data, forKey: key)
        let store = WorkspaceDirectoryMarkStore(store: preferences)
        #expect(throws: WorkspaceIndexingFailure.invalidSettings) { try store.loadIndexingSettings(for: root) }
        #expect(preferences.data(forKey: key) == data)
    }

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
