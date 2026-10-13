import Foundation
import Testing
@testable import Lithe
@testable import LitheGitModule

@MainActor
struct MacGitChangelistStorageTests {
    @Test
    func persistsPerWorkspaceAndRejectsCorruptionWithoutOverwritingIt() throws {
        let store = ChangelistPreferenceStore()
        let storage = MacGitChangelistStorage(store: store)
        let workspace = URL(fileURLWithPath: "/workspace/project")
        let other = URL(fileURLWithPath: "/workspace/other")
        var state = GitLocalChangelists()
        state.lists.append(GitLocalChangelist(id: "local", name: "Local"))
        state.activeID = "local"
        state.assignments[workspace.path] = ["config.yaml": "local"]
        try storage.save(state, workspace: workspace)
        #expect(try MacGitChangelistStorage(store: store).load(workspace: workspace) == state)
        #expect(try storage.load(workspace: other) == nil)
        let key = try #require(store.values.keys.first)
        let corrupt = Data("invalid".utf8)
        store.values[key] = corrupt
        #expect(throws: (any Error).self) { try storage.load(workspace: workspace) }
        #expect(store.data(forKey: key) == corrupt)
    }

    @Test
    func aRejectedPreferenceWriteIsReported() {
        let store = ChangelistPreferenceStore()
        store.rejectWrites = true
        let storage = MacGitChangelistStorage(store: store)
        #expect(throws: (any Error).self) {
            try storage.save(GitLocalChangelists(), workspace: URL(fileURLWithPath: "/workspace"))
        }
    }
}

private final class ChangelistPreferenceStore: KeyValueStore {
    var values: [String: Any] = [:]
    var rejectWrites = false
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { if !rejectWrites { values[key] = value } }
}
