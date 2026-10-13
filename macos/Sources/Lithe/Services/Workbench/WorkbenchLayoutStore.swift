import Foundation

struct WorkbenchLayout: Codable, Sendable {
    // IDEA's ide.mainSplitter.min.size applies to each outer pane and the editor.
    static let minimumPaneSize: Double = 30
    static let minimumSidebarWidth = minimumPaneSize
    static let defaultMavenPaneWidth: Double = 360
    let sidebarWidth: Double
    let topPaneHeight: Double?
    let mavenPaneWidth: Double?
    let branchPopupWidth: Double?
    let branchPopupHeight: Double?

    init(sidebarWidth: Double, topPaneHeight: Double?, mavenPaneWidth: Double? = nil, branchPopupWidth: Double? = nil, branchPopupHeight: Double? = nil) {
        self.sidebarWidth = sidebarWidth
        self.topPaneHeight = topPaneHeight
        self.mavenPaneWidth = mavenPaneWidth
        self.branchPopupWidth = branchPopupWidth
        self.branchPopupHeight = branchPopupHeight
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
              layout.sidebarWidth.isFinite,
              layout.sidebarWidth >= WorkbenchLayout.minimumPaneSize,
              (layout.mavenPaneWidth.map({ $0.isFinite && $0 >= WorkbenchLayout.minimumPaneSize }) ?? true),
              (layout.branchPopupWidth.map({ $0.isFinite && $0 > 0 }) ?? true),
              layout.branchPopupHeight.map({ $0.isFinite && $0 > 0 }) ?? true else {
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
