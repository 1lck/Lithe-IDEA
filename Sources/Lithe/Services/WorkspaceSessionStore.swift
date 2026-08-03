import Foundation

struct WorkspaceSession: Codable, Sendable {
    let openPaths: [String]
    let activePath: String?
    let selectedSidebar: String
}

struct WorkspaceSessionStore {
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
