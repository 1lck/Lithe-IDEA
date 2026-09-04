import Foundation
import Testing
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
}

private final class DirectoryMarkKeyValueStore: KeyValueStore {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
