import Foundation

struct WorkspaceSession: Codable, Sendable {
    let openPaths: [String]
    let activePath: String?
    let selectedSidebar: String
}

enum WorkspaceSessionStore {
    private static let keyPrefix = "lithe.workspace-session."

    static func load(for workspaceURL: URL) -> WorkspaceSession? {
        guard let data = UserDefaults.standard.data(forKey: key(for: workspaceURL)) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSession.self, from: data)
    }

    static func save(_ session: WorkspaceSession, for workspaceURL: URL) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key(for: workspaceURL))
    }

    private static func key(for workspaceURL: URL) -> String {
        keyPrefix + workspaceURL.standardizedFileURL.path
    }
}
