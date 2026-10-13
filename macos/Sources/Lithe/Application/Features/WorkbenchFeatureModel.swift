import Combine
import Foundation
import LitheModuleAPI

/// Owns the left and right docks and the bottom tool window. Each area shows at most one
/// tool window, and the three areas open and close independently of each other.
///
/// AppModel keeps compatibility accessors for existing callers while new
/// workbench code can depend on this focused state model directly.
@MainActor
final class WorkbenchFeatureModel: ObservableObject {
    /// Shell-owned entries keep their preferences even when an optional engine
    /// is disabled. The registered action decides whether they can execute.
    static let mainToolbarContributions: [ModuleContribution] = [
        .init(id: "workbench.toolbar.run", kind: .command, title: "Run",
              placement: .toolbar, order: 100, actionID: "workbench.run-start-or-restart", uiIcon: .init(host: "run")),
        .init(id: "workbench.toolbar.debug", kind: .command, title: "Debug",
              placement: .toolbar, order: 200, actionID: "workbench.debug-start-or-restart", uiIcon: .init(host: "debug")),
        .init(id: "workbench.toolbar.stop", kind: .command, title: "Stop", placement: .toolbar,
              order: 300, actionID: "workbench.stop-execution")
    ]
    static let commandPaletteContributions = LitheCommandCatalog.commands.enumerated().map { order, command in
        ModuleContribution(id: "workbench.command." + command.id, kind: .command, title: command.title,
            placement: .commandPalette, order: order, actionID: command.id)
    }
    static let shellContributions = mainToolbarContributions + commandPaletteContributions
    struct ToolWindow: RawRepresentable, Hashable, Codable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let project = Self(rawValue: "workspace.project")
        static let changes = Self(rawValue: "git.changes")
        static let search = Self(rawValue: "search.workspace")
        static let pullRequests = Self(rawValue: "github.pull-requests")
        static let gitLog = Self(rawValue: "git.log")
        static let terminal = Self(rawValue: "terminal.sessions")
        static let agent = Self(rawValue: "agent.conversation")
        static let database = Self(rawValue: "database.workspace")
        static let databaseServices = Self(rawValue: "database.services")
        static let references = Self(rawValue: "language.references")
        static let problems = Self(rawValue: "language.problems")
        static let maven = Self(rawValue: "execution.maven")
        static let mavenOutput = Self(rawValue: "execution.maven.output")
        static let spring = Self(rawValue: "language.spring")
        static let run = Self(rawValue: "execution.run")
        static let tests = Self(rawValue: "execution.tests")
        static let debug = Self(rawValue: "debug.session")
    }

    struct ContributionPreference: Codable, Equatable, Sendable {
        var placement: ModuleContributionPlacement?
        var order: Int?
        var isHidden = false
    }

    @Published private(set) var contributionPreferences: [String: ContributionPreference] = [:]
    private var toolPlacements: [String: ModuleContributionPlacement] = [:]
    private var contributionOwners: [ModuleID: [ModuleContribution]] = [:]
    private var layoutWorkspaceURL: URL?

    @Published private(set) var activeLeftToolWindow: ToolWindow? = .project
    private var lastLeftToolWindow: ToolWindow = .project
    private var lastSidebarDestination: SidebarDestination = .project
    var selectedSidebar: SidebarDestination {
        get { lastSidebarDestination }
        set {
            // Old workspace sessions can outlive an uninstalled/disabled plugin.
            let id = newValue.contributionID
            let available = contributionOwners.isEmpty || toolPlacements[id] != nil
            setVisibility(available ? .init(rawValue: id) : .project, isVisible: true)
        }
    }
    var isSidebarVisible: Bool { activeLeftToolWindow != nil }
    @Published var isSettingsPresented = false
    @Published private(set) var requestedSettingsCategory: SettingsCategory = .general
    /// Increments with every request, so an open Settings window moves to the
    /// category again even when the same one was requested before and the user
    /// has since navigated away.
    @Published private(set) var settingsCategoryRequest = 0
    @Published var isCloneRepositoryPresented = false
    @Published private(set) var activeToolWindow: ToolWindow?
    @Published private(set) var activeRightToolWindow: ToolWindow?

    private let layoutStore: WorkbenchLayoutStore?
    private var sidebarSelectionHandler: ((SidebarDestination) -> Void)?

    init(layoutStore: WorkbenchLayoutStore? = nil) {
        self.layoutStore = layoutStore
    }

    func configure(
        onSidebarSelectionChanged handler: @escaping (SidebarDestination) -> Void
    ) {
        sidebarSelectionHandler = handler
    }

    /// Tool windows docked beside the editor instead of below it. Maven's
    /// navigation tree and the Agent conversation both need the editor to stay
    /// visible while they are open.
    static func isRightDocked(_ toolWindow: ToolWindow) -> Bool {
        switch toolWindow {
        case .maven, .agent, .database: true
        default: false
        }
    }

    private func placement(of toolWindow: ToolWindow) -> ModuleContributionPlacement {
        if let placement = contributionPreferences[toolWindow.rawValue]?.placement ?? toolPlacements[toolWindow.rawValue] {
            return placement
        }
        if [.project, .changes, .search, .pullRequests].contains(toolWindow) { return .leftSidebar }
        return Self.isRightDocked(toolWindow) ? .rightSidebar : .activityBar
    }

    func isVisible(_ toolWindow: ToolWindow) -> Bool {
        switch placement(of: toolWindow) {
        case .leftSidebar: activeLeftToolWindow == toolWindow
        case .rightSidebar: activeRightToolWindow == toolWindow
        default: activeToolWindow == toolWindow
        }
    }

    func setVisibility(_ toolWindow: ToolWindow, isVisible: Bool) {
        defer { persistContributionPreferences() }
        if isVisible, contributionPreferences[toolWindow.rawValue]?.isHidden == true {
            contributionPreferences[toolWindow.rawValue]?.isHidden = false
        }
        switch placement(of: toolWindow) {
        case .leftSidebar:
            if isVisible {
                if activeLeftToolWindow != toolWindow { activeLeftToolWindow = toolWindow }
                lastLeftToolWindow = toolWindow
            } else if activeLeftToolWindow == toolWindow {
                activeLeftToolWindow = nil
            }
        case .rightSidebar:
            if isVisible {
                if activeRightToolWindow != toolWindow { activeRightToolWindow = toolWindow }
            } else if activeRightToolWindow == toolWindow { activeRightToolWindow = nil }
        default:
            if isVisible {
                if activeToolWindow != toolWindow { activeToolWindow = toolWindow }
            } else if activeToolWindow == toolWindow { activeToolWindow = nil }
        }
        if isVisible, placement(of: toolWindow) == .leftSidebar || [.project, .changes, .search, .pullRequests].contains(toolWindow) {
            let destination = SidebarDestination(contributionID: toolWindow.rawValue)
            if lastSidebarDestination != destination {
                lastSidebarDestination = destination
                sidebarSelectionHandler?(destination)
            }
        }
    }

    func toggleVisibility(_ toolWindow: ToolWindow) {
        setVisibility(toolWindow, isVisible: !isVisible(toolWindow))
    }

    func hideBottomToolWindow() {
        activeToolWindow = nil
        persistContributionPreferences()
    }

    func hideAllToolWindows() {
        hideBottomToolWindow()
        activeRightToolWindow = nil
        activeLeftToolWindow = nil
        persistContributionPreferences()
    }

    /// Catalog changes do not instantiate modules or destroy saved layout for
    /// a temporarily disabled plugin. Only currently unavailable windows close.
    func reconcileContributions(_ owners: [ModuleID: [ModuleContribution]]) {
        contributionOwners = owners
        contributionOwners[.workspace, default: []] += Self.shellContributions
        // The existing Agent setup entry remains available before enablement.
        if contributionOwners[.agentConversation] == nil {
            contributionOwners[.agentConversation] = BuiltInModuleCatalog.contributions(for: .agentConversation)
        }
        toolPlacements = Dictionary(uniqueKeysWithValues: contributionOwners.values.flatMap { $0 }
            .filter { $0.kind == .toolWindow }.map { ($0.id, $0.placement) })
        let available = Set(toolPlacements.keys)
        if let activeLeftToolWindow, !available.contains(activeLeftToolWindow.rawValue) { self.activeLeftToolWindow = nil }
        if let activeToolWindow, !available.contains(activeToolWindow.rawValue) { self.activeToolWindow = nil }
        if let activeRightToolWindow, !available.contains(activeRightToolWindow.rawValue) {
            self.activeRightToolWindow = nil
        }
    }

    func releaseContributions(for moduleID: ModuleID) {
        // Releasing resources is not a user layout edit. Agent keeps its
        // host-owned setup panel when its optional processes are disabled.
        guard moduleID != .agentConversation else { return }
        let ids = Set((contributionOwners[moduleID] ?? []).filter { $0.kind == .toolWindow }.map(\.id))
        if let activeLeftToolWindow, ids.contains(activeLeftToolWindow.rawValue) { self.activeLeftToolWindow = nil }
        if let activeToolWindow, ids.contains(activeToolWindow.rawValue) { self.activeToolWindow = nil }
        if let activeRightToolWindow, ids.contains(activeRightToolWindow.rawValue) { self.activeRightToolWindow = nil }
    }

    func contributions(_ catalog: [ModuleContribution], at placement: ModuleContributionPlacement) -> [ModuleContribution] {
        catalog.filter {
            let preference = contributionPreferences[$0.id]
            return preference?.isHidden != true && (preference?.placement ?? $0.placement) == placement
        }.sorted {
            (contributionPreferences[$0.id]?.order ?? $0.order, $0.id)
                < (contributionPreferences[$1.id]?.order ?? $1.order, $1.id)
        }
    }

    func customizeContribution(_ id: String, placement: ModuleContributionPlacement? = nil, order: Int? = nil, isHidden: Bool? = nil) {
        guard let contribution = contributionOwners.values.flatMap({ $0 }).first(where: { $0.id == id }) else { return }
        if let placement {
            guard contribution.kind == .toolWindow && [.activityBar, .leftSidebar, .rightSidebar].contains(placement) else { return }
        }
        let window = ToolWindow(rawValue: id)
        let wasVisible = contribution.kind == .toolWindow && isVisible(window)
        if wasVisible { setVisibility(window, isVisible: false) }
        var preference = contributionPreferences[id] ?? ContributionPreference()
        if let placement { preference.placement = placement }
        if let order { preference.order = order }
        if let isHidden { preference.isHidden = isHidden }
        contributionPreferences[id] = preference
        if wasVisible && !preference.isHidden { setVisibility(window, isVisible: true) }
        persistContributionPreferences()
    }

    func moveContribution(_ id: String, earlier: Bool) {
        let catalog = contributionOwners.values.flatMap { $0 }
        guard let contribution = catalog.first(where: { $0.id == id }) else { return }
        let placement = contributionPreferences[id]?.placement ?? contribution.placement
        let entries = contributions(catalog, at: placement)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let neighbor = index + (earlier ? -1 : 1)
        guard entries.indices.contains(neighbor) else { return }
        var reordered = entries
        reordered.swapAt(index, neighbor)
        // Equal default orders still move deterministically; assign the complete
        // current region rather than subtracting from possibly equal ranks.
        for (order, entry) in reordered.enumerated() {
            var preference = contributionPreferences[entry.id] ?? ContributionPreference()
            preference.order = order
            contributionPreferences[entry.id] = preference
        }
        persistContributionPreferences()
    }

    func resetContributionPreferences() {
        hideAllToolWindows()
        contributionPreferences = [:]
        setVisibility(.project, isVisible: true)
        persistContributionPreferences()
    }

    private func persistContributionPreferences() {
        guard let layoutWorkspaceURL, let layoutStore else { return }
        layoutStore.saveUIState(contributionPreferences,
            visibleIDs: [activeToolWindow, activeRightToolWindow].compactMap { $0?.rawValue },
            sidebarID: activeLeftToolWindow?.rawValue ?? lastLeftToolWindow.rawValue,
            isSidebarVisible: isSidebarVisible, for: layoutWorkspaceURL)
    }

    func presentSettings(category: SettingsCategory) {
        requestedSettingsCategory = category
        settingsCategoryRequest += 1
        isSettingsPresented = true
    }

    /// Detach persistence before session cleanup closes windows. The last
    /// user-visible state is already saved and must survive quit/project close.
    func endLayoutSession() {
        layoutWorkspaceURL = nil
        hideAllToolWindows()
        contributionPreferences = [:]
    }

    func reset() {
        layoutWorkspaceURL = nil
        hideAllToolWindows()
        contributionPreferences = [:]
        selectedSidebar = .project
        isSettingsPresented = false
        requestedSettingsCategory = .general
        isCloneRepositoryPresented = false
    }

    func loadLayout(for workspaceURL: URL) -> WorkbenchLayout {
        let layout = layoutStore?.load(for: workspaceURL)
            ?? WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil)
        layoutWorkspaceURL = nil
        contributionPreferences = layout.contributionPreferences ?? [:]
        if let visible = layout.isSidebarVisible {
            let window = ToolWindow(rawValue: layout.sidebarToolWindowID ?? ToolWindow.project.rawValue)
            let isAvailable = toolPlacements[window.rawValue] != nil && placement(of: window) == .leftSidebar
                && contributionPreferences[window.rawValue]?.isHidden != true
            let destination = SidebarDestination(contributionID: window.rawValue)
            activeLeftToolWindow = visible && isAvailable ? window : nil
            lastLeftToolWindow = window
            let changed = lastSidebarDestination != destination
            lastSidebarDestination = destination
            if changed && activeLeftToolWindow != nil { sidebarSelectionHandler?(destination) }
        }
        layoutWorkspaceURL = workspaceURL
        return layout
    }

    func saveLayout(_ layout: WorkbenchLayout, for workspaceURL: URL) {
        layoutStore?.save(layout, for: workspaceURL)
    }

    func setSelectedSidebar(_ destination: SidebarDestination) {
        selectedSidebar = destination
    }

    func hideSidebar() {
        activeLeftToolWindow = nil
        persistContributionPreferences()
    }
}
