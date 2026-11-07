import Foundation
import LitheModuleAPI

/// Persists the recent project list. Rust Core owns which projects are kept
/// and their order (`workspace.recentProjects.reduce`); this store only adds
/// the native metadata (branch) and the `KeyValueStore` persistence.
struct RecentProjectsStore {
    private static let key = "lithe.recent-projects"
    private let store: any KeyValueStore
    private let core: RustCoreBridge
    /// Roots that are not worth reopening from the list, such as remote
    /// workspace placeholders that need a live connection.
    private let excludes: (URL) -> Bool

    init(store: any KeyValueStore, core: RustCoreBridge = RustCoreBridge(), excludes: @escaping (URL) -> Bool = { _ in false }) {
        self.store = store
        self.core = core
        self.excludes = excludes
    }

    func load() -> [RecentProject] {
        guard let data = store.data(forKey: Self.key),
              let projects = try? JSONDecoder().decode([RecentProject].self, from: data) else {
            return []
        }
        return reduce(projects, action: .normalize) ?? projects
    }

    func record(_ url: URL, branch: String? = nil, in projects: [RecentProject]) -> [RecentProject] {
        guard !excludes(url) else { return projects }
        let openedAt = Date()
        guard let reduced = reduce(projects, action: .record(path: url.path, openedAt: openedAt)) else {
            return projects
        }
        // Replace the entry instead of editing it so an old branch of a folder
        // that is no longer a repository is cleared rather than kept stale.
        let updated = reduced.map { project in
            project.path == url.path ? RecentProject(path: url.path, lastOpened: project.lastOpened, branch: branch) : project
        }
        save(updated)
        return updated
    }

    func remove(_ project: RecentProject, from projects: [RecentProject]) -> [RecentProject] {
        guard let updated = reduce(projects, action: .remove(paths: [project.path])) else { return projects }
        save(updated)
        return updated
    }

    private func save(_ projects: [RecentProject]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        store.set(data, forKey: Self.key)
    }

    private enum Action: Encodable {
        case record(path: String, openedAt: Date)
        case remove(paths: [String])
        case normalize

        private enum CodingKeys: String, CodingKey { case kind, path, paths, openedAt }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .record(path, openedAt):
                try container.encode("record", forKey: .kind)
                try container.encode(path, forKey: .path)
                try container.encode(Entry.milliseconds(openedAt), forKey: .openedAt)
            case let .remove(paths):
                try container.encode("remove", forKey: .kind)
                try container.encode(paths, forKey: .paths)
            case .normalize:
                try container.encode("normalize", forKey: .kind)
            }
        }
    }

    private struct Entry: Codable {
        let path: String
        let lastOpenedAt: Int64
        let pinned: Bool

        static func milliseconds(_ date: Date) -> Int64 {
            Int64(max(0, (date.timeIntervalSince1970 * 1000).rounded()))
        }
    }

    /// Returns the Core-retained list with each project's branch carried over,
    /// or `nil` when Core rejected the request (already logged).
    private func reduce(_ projects: [RecentProject], action: Action) -> [RecentProject]? {
        struct Request: Encodable { let entries: [Entry]; let action: Action }
        struct Response: Decodable { let entries: [Entry] }
        let entries = projects.map { Entry(path: $0.path, lastOpenedAt: Entry.milliseconds($0.lastOpened), pinned: false) }
        let result: Result<Response, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "workspace.recentProjects.reduce", payload: Request(entries: entries, action: action))
        switch result {
        case .success(let response):
            let branches = Dictionary(projects.map { ($0.path, $0.branch) }, uniquingKeysWith: { first, _ in first })
            return response.entries.map { entry in
                RecentProject(path: entry.path,
                              lastOpened: Date(timeIntervalSince1970: TimeInterval(entry.lastOpenedAt) / 1000),
                              branch: branches[entry.path] ?? nil)
            }
        case .failure(let error):
            core.coreLogSink?.emit(AppCoreFallbackSelected(error: LogFailure(domain: "RustCore", code: error.code), stage: "workspace.recentProjects.reduce"))
            return nil
        }
    }
}
