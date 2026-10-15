import Foundation

enum DockAnchor: String, Codable, CaseIterable, Sendable { case left, right, bottom }
enum DockGroup: String, Codable, CaseIterable, Sendable { case primary, secondary }

struct DockPosition: Codable, Hashable, Sendable {
    let anchor: DockAnchor
    let group: DockGroup
}

struct ToolWindowState: Codable, Equatable, Sendable {
    let id: String
    var position: DockPosition
    var order: Int
    var isVisible: Bool
}

struct WorkbenchLayout: Codable, Sendable {
    // IDEA's ide.mainSplitter.min.size applies to each outer pane and the editor.
    static let minimumPaneSize: Double = 30
    static let minimumSidebarWidth = minimumPaneSize
    static let defaultMavenPaneWidth: Double = 360
    var toolWindows: [ToolWindowState]?
    var groupFractions: [String: Double]?
    let sidebarWidth: Double
    let topPaneHeight: Double?
    let mavenPaneWidth: Double?
    let branchPopupWidth: Double?
    let branchPopupHeight: Double?
    var sidebarToolWindowID: String?
    var isSidebarVisible: Bool?
    var visibleToolWindowIDs: [String]?
    var contributionPreferences: [String: WorkbenchFeatureModel.ContributionPreference]?

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
        var layout = layout
        // Geometry commits must not overwrite customization saved by a command.
        if layout.contributionPreferences == nil || layout.isSidebarVisible == nil || layout.visibleToolWindowIDs == nil {
            let saved = load(for: workspaceURL)
            if layout.contributionPreferences == nil { layout.contributionPreferences = saved.contributionPreferences }
            if layout.isSidebarVisible == nil {
                layout.isSidebarVisible = saved.isSidebarVisible
                layout.sidebarToolWindowID = saved.sidebarToolWindowID
            }
            if layout.visibleToolWindowIDs == nil { layout.visibleToolWindowIDs = saved.visibleToolWindowIDs }
        }
        guard let data = try? JSONEncoder().encode(layout) else { return }
        store.set(data, forKey: key(for: workspaceURL))
    }

    func saveUIState(_ preferences: [String: WorkbenchFeatureModel.ContributionPreference], visibleIDs: [String], sidebarID: String, isSidebarVisible: Bool, toolWindows: [ToolWindowState]? = nil, groupFractions: [String: Double]? = nil, for workspaceURL: URL) {
        var layout = load(for: workspaceURL)
        layout.contributionPreferences = preferences
        layout.visibleToolWindowIDs = visibleIDs
        layout.sidebarToolWindowID = sidebarID
        layout.isSidebarVisible = isSidebarVisible
        if let toolWindows { layout.toolWindows = toolWindows }
        if let groupFractions { layout.groupFractions = groupFractions }
        save(layout, for: workspaceURL)
    }

    private func key(for workspaceURL: URL) -> String {
        Self.keyPrefix + workspaceURL.standardizedFileURL.path
    }
}
