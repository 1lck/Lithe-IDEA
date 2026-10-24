import Foundation

struct RecentProjectsStore {
    private static let key = "lithe.recent-projects"
    private let store: any KeyValueStore
    /// Roots that are not worth reopening from the list, such as remote
    /// workspace placeholders that need a live connection.
    private let excludes: (URL) -> Bool

    init(store: any KeyValueStore, excludes: @escaping (URL) -> Bool = { _ in false }) {
        self.store = store
        self.excludes = excludes
    }

    func load() -> [RecentProject] {
        guard let data = store.data(forKey: Self.key),
              let projects = try? JSONDecoder().decode([RecentProject].self, from: data) else {
            return []
        }
        return projects.sorted { $0.lastOpened > $1.lastOpened }
    }

    func record(_ url: URL, branch: String? = nil, in projects: [RecentProject]) -> [RecentProject] {
        guard !excludes(url) else { return projects }
        var updated = projects.filter { $0.path != url.path }
        // Replace the entry instead of editing it so an old branch of a folder
        // that is no longer a repository is cleared rather than kept stale.
        updated.insert(RecentProject(path: url.path, lastOpened: Date(), branch: branch), at: 0)
        updated = Array(updated.prefix(20))
        save(updated)
        return updated
    }

    func remove(_ project: RecentProject, from projects: [RecentProject]) -> [RecentProject] {
        let updated = projects.filter { $0.id != project.id }
        save(updated)
        return updated
    }

    private func save(_ projects: [RecentProject]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        store.set(data, forKey: Self.key)
    }
}
