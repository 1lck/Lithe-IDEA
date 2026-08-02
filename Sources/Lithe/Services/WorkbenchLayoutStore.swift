import Foundation

struct WorkbenchLayout: Codable, Sendable {
    let sidebarWidth: Double
    let topPaneHeight: Double?
}

enum WorkbenchLayoutStore {
    private static let keyPrefix = "lithe.workbench-layout."
    private static let defaultLayout = WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil)

    static func load(for workspaceURL: URL) -> WorkbenchLayout {
        guard let data = UserDefaults.standard.data(forKey: key(for: workspaceURL)),
              let layout = try? JSONDecoder().decode(WorkbenchLayout.self, from: data),
              layout.sidebarWidth >= 220,
              layout.sidebarWidth <= 520 else {
            return defaultLayout
        }
        return layout
    }

    static func save(_ layout: WorkbenchLayout, for workspaceURL: URL) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: key(for: workspaceURL))
    }

    private static func key(for workspaceURL: URL) -> String {
        keyPrefix + workspaceURL.standardizedFileURL.path
    }
}
