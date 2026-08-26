import Foundation
import LitheCoreContracts

typealias WorkspaceSession = LitheCoreContracts.WorkspaceSession

@MainActor
final class WorkspaceSessionStore: WorkspaceSessionStoring {
    private static let keyPrefix = "lithe.workspace-session."
    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func load(for workspaceURL: URL) -> WorkspaceSession? {
        guard let data = store.data(forKey: key(for: workspaceURL)) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSession.self, from: data)
    }

    func save(_ session: WorkspaceSession, for workspaceURL: URL) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        store.set(data, forKey: key(for: workspaceURL))
    }

    private func key(for workspaceURL: URL) -> String {
        Self.keyPrefix + workspaceURL.standardizedFileURL.path
    }
}
