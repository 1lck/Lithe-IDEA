import Foundation

enum RecentProjectsStore {
    private static let key = "lithe.recent-projects"

    static func load() -> [RecentProject] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let projects = try? JSONDecoder().decode([RecentProject].self, from: data) else {
            return []
        }
        return projects.sorted { $0.lastOpened > $1.lastOpened }
    }

    static func record(_ url: URL, in projects: [RecentProject]) -> [RecentProject] {
        var updated = projects.filter { $0.path != url.path }
        updated.insert(RecentProject(path: url.path, lastOpened: Date()), at: 0)
        updated = Array(updated.prefix(20))
        save(updated)
        return updated
    }

    static func remove(_ project: RecentProject, from projects: [RecentProject]) -> [RecentProject] {
        let updated = projects.filter { $0.id != project.id }
        save(updated)
        return updated
    }

    private static func save(_ projects: [RecentProject]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
