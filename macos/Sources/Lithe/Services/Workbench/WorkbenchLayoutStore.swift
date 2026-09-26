import Foundation

struct WorkbenchLayout: Codable, Sendable {
    static let minimumSidebarWidth: Double = 30
    static let defaultMavenPaneWidth: Double = 360
    static let minimumMavenPaneWidth: Double = 300
    static let maximumMavenPaneWidth: Double = 520
    let sidebarWidth: Double
    let topPaneHeight: Double?
    let mavenPaneWidth: Double?

    init(sidebarWidth: Double, topPaneHeight: Double?, mavenPaneWidth: Double? = nil) {
        self.sidebarWidth = sidebarWidth
        self.topPaneHeight = topPaneHeight
        self.mavenPaneWidth = mavenPaneWidth
    }
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
              layout.sidebarWidth >= WorkbenchLayout.minimumSidebarWidth,
              layout.sidebarWidth <= 520,
              layout.mavenPaneWidth.map({ $0.isFinite && $0 > 0 && $0 <= WorkbenchLayout.maximumMavenPaneWidth }) ?? true else {
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
