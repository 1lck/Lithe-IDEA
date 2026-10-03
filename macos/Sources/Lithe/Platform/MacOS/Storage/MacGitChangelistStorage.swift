import Foundation
import LitheGitModule

/// User preferences own this metadata for the lifetime of a workspace. No files
/// are written into the repository or app bundle; signatures and update deltas stay intact.
@MainActor
final class MacGitChangelistStorage: GitChangelistStorage {
    private let store: any KeyValueStore

    init(store: any KeyValueStore) { self.store = store }

    func load(workspace: URL) throws -> GitLocalChangelists? {
        let key = key(workspace)
        guard let value = store.object(forKey: key) else { return nil }
        guard let data = value as? Data else { throw StorageFailure.invalidData }
        let state = try JSONDecoder().decode(GitLocalChangelists.self, from: data)
        guard state.isValid else { throw StorageFailure.invalidData }
        return state
    }

    func save(_ state: GitLocalChangelists, workspace: URL) throws {
        guard state.isValid else { throw StorageFailure.invalidData }
        let data = try JSONEncoder().encode(state)
        let key = key(workspace)
        store.set(data, forKey: key)
        guard store.data(forKey: key) == data else { throw StorageFailure.writeFailed }
    }

    private func key(_ workspace: URL) -> String {
        "lithe.git.local-changelists.v1:" + workspace.standardizedFileURL.path
    }

    private enum StorageFailure: Error { case invalidData, writeFailed }
}
