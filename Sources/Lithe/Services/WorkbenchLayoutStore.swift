import Foundation

struct WorkbenchLayout: Codable, Sendable {
    let sidebarWidth: Double
    let topPaneHeight: Double?
}

struct WorkbenchLayoutStore {
    private static let keyPrefix = "lithe.workbench-layout."
    private static let defaultLayout = WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil)
    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func load(for workspaceURL: URL) -> WorkbenchLayout {
        guard let data = store.data(forKey: key(for: workspaceURL)),
              let layout = try? JSONDecoder().decode(WorkbenchLayout.self, from: data),
              layout.sidebarWidth >= 220,
              layout.sidebarWidth <= 520 else {
            return Self.defaultLayout
        }
        return layout
    }

    func save(_ layout: WorkbenchLayout, for workspaceURL: URL) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        store.set(data, forKey: key(for: workspaceURL))
    }

    private func key(for workspaceURL: URL) -> String {
        Self.keyPrefix + workspaceURL.standardizedFileURL.path
    }
}
