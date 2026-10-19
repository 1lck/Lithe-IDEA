import Combine
import Foundation
import LitheModuleAPI

/// Owns registered tool-window positions and visibility. Each dock group shows
/// one window; feature modules retain their content and resources.
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
    struct ToolWindow: RawRepresentable, Hashable, Codable, Sendable, CaseIterable {
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
        static let spring = Self(rawValue: "language.spring")
        static let run = Self(rawValue: "execution.run")
        static let tests = Self(rawValue: "execution.tests")
        static let debug = Self(rawValue: "debug.session")
        static let buildOutput = Self(rawValue: "execution.build.output")
        static let allCases: [Self] = [.project, .changes, .pullRequests, .search, .database,
            .gitLog, .terminal, .agent, .databaseServices, .references, .problems, .spring, .run, .tests, .debug,
            .buildOutput]
        // Docking layouts written before contribution registration used enum case names.
        // Their windows may since have been removed, so the mapping names the
        // old IDs instead of following `allCases`; an ID with no window left
        // is dropped like any unknown contribution.
        static func restoredID(_ id: String) -> String {
            let legacy = [
                "project": "workspace.project", "changes": "git.changes", "pullRequests": "github.pull-requests",
                "search": "search.workspace", "database": "database.workspace", "gitLog": "git.log",
                "terminal": "terminal.sessions", "agent": "agent.conversation", "databaseServices": "database.services",
                "references": "language.references", "problems": "language.problems", "maven": "execution.maven",
                "mavenOutput": "execution.maven.output", "spring": "language.spring", "run": "execution.run",
                "tests": "execution.tests", "debug": "debug.session"
            ]
            return legacy[id] ?? id
        }
    }

    struct ContributionPreference: Codable, Equatable, Sendable {
        var placement: ModuleContributionPlacement?
        var order: Int?
        var isHidden = false
    }

    @Published private(set) var contributionPreferences: [String: ContributionPreference] = [:]
    private var toolPlacements: [String: ModuleContributionPlacement] = [:]
    private var contributionOwners: [ModuleID: [ModuleContribution]] = [:]
    private var displayRequests: [DockPosition: UUID] = [:]
    private var layoutWorkspaceURL: URL?
    private var layoutSessionEnded = false

    @Published private(set) var toolWindowStates = ToolWindow.allCases.enumerated().map {
        ToolWindowState(id: $0.element.rawValue,
            position: .init(anchor: [.project, .changes, .search, .pullRequests].contains($0.element) ? .left :
                (isRightDocked($0.element) ? .right : .bottom), group: .primary),
            order: $0.offset, isVisible: $0.element == .project)
    }
    @Published private(set) var groupFractions: [String: Double] = [:]
    var activeLeftToolWindow: ToolWindow? { activeTool(in: .init(anchor: .left, group: .primary)) }
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
    var isSidebarVisible: Bool { toolWindowStates.contains { $0.position.anchor == .left && $0.isVisible } }
    @Published var isSettingsPresented = false
    @Published private(set) var requestedSettingsCategory: SettingsCategory = .general
    /// Increments with every request, so an open Settings window moves to the
    /// category again even when the same one was requested before and the user
    /// has since navigated away.
    @Published private(set) var settingsCategoryRequest = 0
    @Published var isCloneRepositoryPresented = false
    var activeToolWindow: ToolWindow? { activeTool(in: .init(anchor: .bottom, group: .primary)) }
    var activeRightToolWindow: ToolWindow? { activeTool(in: .init(anchor: .right, group: .primary)) }

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

    /// Tool windows docked beside the editor instead of below it. The Agent
    /// conversation and the database tree need the editor to stay visible
    /// while they are open. Contributed windows, such as a build system's,
    /// dock where their placement says.
    static func isRightDocked(_ toolWindow: ToolWindow) -> Bool {
        switch toolWindow {
        case .agent, .database: true
        default: false
        }
    }

    private static func placement(for anchor: DockAnchor) -> ModuleContributionPlacement {
        switch anchor { case .left: .leftSidebar; case .right: .rightSidebar; case .bottom: .activityBar }
    }

    private static func anchor(for placement: ModuleContributionPlacement) -> DockAnchor {
        switch placement { case .leftSidebar: .left; case .rightSidebar: .right; default: .bottom }
    }

    func state(for tool: ToolWindow) -> ToolWindowState {
        toolWindowStates.first { $0.id == tool.rawValue } ?? ToolWindowState(id: tool.rawValue,
            position: .init(anchor: Self.isRightDocked(tool) ? .right : .bottom, group: .primary), order: 0, isVisible: false)
    }

    func tools(in position: DockPosition) -> [ToolWindow] {
        toolWindowStates.filter { $0.position == position }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            .map { ToolWindow(rawValue: $0.id) }
    }

    func activeTool(in position: DockPosition) -> ToolWindow? {
        tools(in: position).first { isVisible($0) }
    }

    func isVisible(_ toolWindow: ToolWindow) -> Bool { state(for: toolWindow).isVisible }

    /// Requests are scoped to a dock group, so other groups can activate independently.
    func beginDisplayRequest(for tool: ToolWindow) -> (position: DockPosition, token: UUID) {
        let request = (position: state(for: tool).position, token: UUID())
        displayRequests[request.position] = request.token
        return request
    }

    func isCurrentDisplayRequest(_ request: (position: DockPosition, token: UUID), for tool: ToolWindow) -> Bool {
        state(for: tool).position == request.position && displayRequests[request.position] == request.token
    }

    func setVisibility(_ toolWindow: ToolWindow, isVisible: Bool) {
        if isVisible, contributionPreferences[toolWindow.rawValue]?.isHidden == true {
            contributionPreferences[toolWindow.rawValue]?.isHidden = false
        }
        let position = state(for: toolWindow).position
        displayRequests.removeValue(forKey: position)
        var states = toolWindowStates
        if !states.contains(where: { $0.id == toolWindow.rawValue }) { states.append(state(for: toolWindow)) }
        for index in states.indices {
            if states[index].id == toolWindow.rawValue {
                states[index].isVisible = isVisible
            } else if isVisible && states[index].position == position {
                states[index].isVisible = false
            }
        }
        if states != toolWindowStates { toolWindowStates = states }
        if isVisible {
            if position.anchor == .left { lastLeftToolWindow = toolWindow }
            if position.anchor == .left || [.project, .changes, .search, .pullRequests].contains(toolWindow) {
                let destination = SidebarDestination(contributionID: toolWindow.rawValue)
                if lastSidebarDestination != destination {
                    lastSidebarDestination = destination
                    sidebarSelectionHandler?(destination)
                }
            }
        }
        persistContributionPreferences()
    }

    /// Commit one atomic move. Hover previews never mutate persisted layout.
    func move(_ tool: ToolWindow, to position: DockPosition, before target: ToolWindow? = nil) {
        guard target != tool else { return }
        var states = toolWindowStates
        guard let index = states.firstIndex(where: { $0.id == tool.rawValue }) else { return }
        let wasVisible = states[index].isVisible
        displayRequests.removeValue(forKey: states[index].position)
        displayRequests.removeValue(forKey: position)
        states[index].position = position
        if wasVisible {
            for other in states.indices where other != index && states[other].position == position {
                states[other].isVisible = false
            }
        }
        var order = states.filter { $0.position == position && $0.id != tool.rawValue }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }.map(\.id)
        let insertion = target.flatMap { order.firstIndex(of: $0.rawValue) } ?? order.count
        order.insert(tool.rawValue, at: insertion)
        for (offset, id) in order.enumerated() {
            if let i = states.firstIndex(where: { $0.id == id }) { states[i].order = offset }
        }
        if states != toolWindowStates { toolWindowStates = states }
        for state in states where state.position == position {
            var preference = contributionPreferences[state.id] ?? ContributionPreference()
            preference.placement = Self.placement(for: position.anchor)
            preference.order = state.order
            contributionPreferences[state.id] = preference
        }
        if wasVisible && position.anchor == .left { lastLeftToolWindow = tool }
        persistContributionPreferences()
    }

    func setGroupFraction(_ value: Double, for anchor: DockAnchor) {
        guard value.isFinite else { return }
        groupFractions[anchor.rawValue] = min(1, max(0, value))
        persistContributionPreferences()
    }

    func toggleVisibility(_ toolWindow: ToolWindow) {
        setVisibility(toolWindow, isVisible: !isVisible(toolWindow))
    }

    func hideBottomToolWindow() {
        displayRequests = displayRequests.filter { $0.key.anchor != .bottom }
        hideToolWindows { $0.position.anchor == .bottom }
        persistContributionPreferences()
    }

    func hideAllToolWindows() {
        displayRequests.removeAll()
        hideToolWindows { _ in true }
        persistContributionPreferences()
    }

    /// Hide in one assignment so observers see a single layout change instead
    /// of one publish per window.
    private func hideToolWindows(where matches: (ToolWindowState) -> Bool) {
        var states = toolWindowStates
        for index in states.indices where matches(states[index]) { states[index].isVisible = false }
        if states != toolWindowStates { toolWindowStates = states }
    }

    /// Catalog changes do not instantiate modules or destroy saved layout for
    /// a temporarily disabled plugin. Only currently unavailable windows close.
    func reconcileContributions(_ owners: [ModuleID: [ModuleContribution]]) {
        contributionOwners = owners
        let shellIDs = Set(Self.shellContributions.map(\.id))
        contributionOwners[.workspace, default: []].removeAll { shellIDs.contains($0.id) }
        contributionOwners[.workspace, default: []] += Self.shellContributions
        // The existing Agent setup entry remains available before enablement.
        if contributionOwners[.agentConversation] == nil {
            contributionOwners[.agentConversation] = BuiltInModuleCatalog.contributions(for: .agentConversation)
        }
        toolPlacements = Dictionary(uniqueKeysWithValues: contributionOwners.values.flatMap { $0 }
            .filter { $0.kind == .toolWindow }.map { ($0.id, $0.placement) })
        let entries = contributionOwners.values.flatMap { $0 }.filter { $0.kind == .toolWindow }.sorted { $0.id < $1.id }
        for entry in entries where !toolWindowStates.contains(where: { $0.id == entry.id }) {
            let preference = contributionPreferences[entry.id]
            toolWindowStates.append(.init(id: entry.id,
                position: .init(anchor: Self.anchor(for: preference?.placement ?? entry.placement), group: .primary),
                order: preference?.order ?? entry.order, isVisible: false))
        }
        let available = Set(toolPlacements.keys)
        hideToolWindows { !available.contains($0.id) }
    }

    func releaseContributions(for moduleID: ModuleID) {
        // Releasing resources is not a user layout edit. Agent keeps its setup panel.
        guard moduleID != .agentConversation else { return }
        let ids = Set((contributionOwners[moduleID] ?? []).filter { $0.kind == .toolWindow }.map(\.id))
        hideToolWindows { ids.contains($0.id) }
    }

    func contributions(_ catalog: [ModuleContribution], at placement: ModuleContributionPlacement) -> [ModuleContribution] {
        catalog.filter {
            let preference = contributionPreferences[$0.id]
            let actual = $0.kind == .toolWindow ? Self.placement(for: state(for: .init(rawValue: $0.id)).position.anchor)
                : (preference?.placement ?? $0.placement)
            return preference?.isHidden != true && actual == placement
        }.sorted {
            let left = $0.kind == .toolWindow ? state(for: .init(rawValue: $0.id)).order
                : (contributionPreferences[$0.id]?.order ?? $0.order)
            let right = $1.kind == .toolWindow ? state(for: .init(rawValue: $1.id)).order
                : (contributionPreferences[$1.id]?.order ?? $1.order)
            return (left, $0.id) < (right, $1.id)
        }
    }

    func customizeContribution(_ id: String, placement: ModuleContributionPlacement? = nil, order: Int? = nil, isHidden: Bool? = nil) {
        guard let contribution = contributionOwners.values.flatMap({ $0 }).first(where: { $0.id == id }) else { return }
        if let placement {
            guard contribution.kind == .toolWindow && [.activityBar, .leftSidebar, .rightSidebar].contains(placement) else { return }
        }
        let window = ToolWindow(rawValue: id)
        // Only a dock change or hiding needs the window closed; reordering or
        // showing an entry must not flicker an open window.
        let wasVisible = contribution.kind == .toolWindow && isVisible(window)
            && (placement != nil || isHidden == true)
        if wasVisible { setVisibility(window, isVisible: false) }
        var preference = contributionPreferences[id] ?? ContributionPreference()
        if let placement { preference.placement = placement }
        if let order { preference.order = order }
        if let isHidden { preference.isHidden = isHidden }
        contributionPreferences[id] = preference
        if let placement { move(window, to: .init(anchor: Self.anchor(for: placement), group: .primary)) }
        if let order, let index = toolWindowStates.firstIndex(where: { $0.id == id }) { toolWindowStates[index].order = order }
        if wasVisible && !preference.isHidden { setVisibility(window, isVisible: true) }
        persistContributionPreferences()
    }

    func moveContribution(_ id: String, earlier: Bool) {
        let catalog = contributionOwners.values.flatMap { $0 }
        guard let contribution = catalog.first(where: { $0.id == id }) else { return }
        let position = state(for: .init(rawValue: id)).position
        let placement = contribution.kind == .toolWindow ? Self.placement(for: position.anchor)
            : (contributionPreferences[id]?.placement ?? contribution.placement)
        let entries = contributions(catalog, at: placement).filter {
            contribution.kind != .toolWindow || state(for: .init(rawValue: $0.id)).position == position
        }
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
            if let index = toolWindowStates.firstIndex(where: { $0.id == entry.id }) { toolWindowStates[index].order = order }
        }
        persistContributionPreferences()
    }

    func resetContributionPreferences() {
        hideAllToolWindows()
        contributionPreferences = [:]
        toolWindowStates = Self().toolWindowStates
        groupFractions = [:]
        let owners = contributionOwners
        reconcileContributions(owners)
        setVisibility(.project, isVisible: true)
        persistContributionPreferences()
    }

    private func persistContributionPreferences() {
        guard let layoutWorkspaceURL, let layoutStore else { return }
        layoutStore.saveUIState(contributionPreferences,
            visibleIDs: toolWindowStates.filter { $0.isVisible && $0.position.anchor != .left }.map(\.id),
            sidebarID: activeLeftToolWindow?.rawValue ?? lastLeftToolWindow.rawValue,
            isSidebarVisible: isSidebarVisible, toolWindows: toolWindowStates, groupFractions: groupFractions, for: layoutWorkspaceURL)
    }

    func presentSettings(category: SettingsCategory) {
        requestedSettingsCategory = category
        settingsCategoryRequest += 1
        isSettingsPresented = true
    }

    /// Detach persistence before session cleanup closes windows. The last
    /// user-visible state is already saved and must survive quit/project close.
    func endLayoutSession() {
        layoutSessionEnded = true
        layoutWorkspaceURL = nil
        hideAllToolWindows()
        contributionPreferences = [:]
    }

    func reset() {
        layoutSessionEnded = true
        layoutWorkspaceURL = nil
        hideAllToolWindows()
        contributionPreferences = [:]
        selectedSidebar = .project
        isSettingsPresented = false
        requestedSettingsCategory = .general
        isCloneRepositoryPresented = false
    }

    func loadLayout(for workspaceURL: URL) -> WorkbenchLayout {
        displayRequests.removeAll()
        layoutSessionEnded = false
        let priorLeft = activeLeftToolWindow
        let layout = layoutStore?.load(for: workspaceURL)
            ?? WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil)
        layoutWorkspaceURL = nil
        contributionPreferences = layout.contributionPreferences ?? [:]
        var states = Self().toolWindowStates
        let registered = contributionOwners.values.flatMap { $0 }.filter { $0.kind == .toolWindow }.sorted { $0.id < $1.id }
        for entry in registered where !states.contains(where: { $0.id == entry.id }) {
            states.append(.init(id: entry.id, position: .init(anchor: Self.anchor(for: entry.placement), group: .primary),
                order: entry.order, isVisible: false))
        }
        if layout.toolWindows == nil {
            for index in states.indices {
                if let preference = contributionPreferences[states[index].id] {
                    if let placement = preference.placement { states[index].position = .init(anchor: Self.anchor(for: placement), group: .primary) }
                    if let order = preference.order { states[index].order = order }
                }
            }
        }
        var seen: Set<String> = []
        var visible: Set<DockPosition> = []
        for saved in layout.toolWindows ?? [] {
            let id = ToolWindow.restoredID(saved.id)
            guard let index = states.firstIndex(where: { $0.id == id }),
                  seen.insert(id).inserted else { continue }
            states[index] = .init(id: id, position: saved.position, order: saved.order, isVisible: saved.isVisible)
            // Opening a project must not launch its Agent panel or process.
            if id == ToolWindow.agent.rawValue { states[index].isVisible = false }
            states[index].order = max(0, saved.order)
            if states[index].isVisible && !visible.insert(saved.position).inserted { states[index].isVisible = false }
        }
        // Missing records retain defaults, but cannot displace restored active windows.
        for index in states.indices where !seen.contains(states[index].id) && states[index].isVisible {
            if !visible.insert(states[index].position).inserted { states[index].isVisible = false }
        }
        if !contributionOwners.isEmpty {
            for index in states.indices where toolPlacements[states[index].id] == nil { states[index].isVisible = false }
        }
        for index in states.indices where contributionPreferences[states[index].id]?.isHidden == true { states[index].isVisible = false }
        toolWindowStates = states
        groupFractions = (layout.groupFractions ?? [:]).filter {
            DockAnchor(rawValue: $0.key) != nil && $0.value.isFinite && (0...1).contains($0.value)
        }
        if layout.toolWindows == nil, let visible = layout.isSidebarVisible {
            let window = ToolWindow(rawValue: ToolWindow.restoredID(layout.sidebarToolWindowID ?? ToolWindow.project.rawValue))
            let available = toolPlacements[window.rawValue] != nil && state(for: window).position.anchor == .left
                && contributionPreferences[window.rawValue]?.isHidden != true
            hideSidebar()
            if visible && available { setVisibility(window, isVisible: true) }
            lastLeftToolWindow = window
        }
        if layout.toolWindows == nil && layout.isSidebarVisible == nil, let priorLeft,
           contributionOwners.isEmpty || toolPlacements[priorLeft.rawValue] != nil {
            setVisibility(priorLeft, isVisible: true)
        }
        let selection = layout.sidebarToolWindowID.map { ToolWindow(rawValue: ToolWindow.restoredID($0)) }
            ?? activeLeftToolWindow
        if let left = selection {
            lastLeftToolWindow = left
            let destination = SidebarDestination(contributionID: left.rawValue)
            let changed = lastSidebarDestination != destination
            lastSidebarDestination = destination
            if changed && isSidebarVisible { sidebarSelectionHandler?(destination) }
        }
        layoutWorkspaceURL = workspaceURL
        return layout
    }

    func saveLayout(_ layout: WorkbenchLayout, for workspaceURL: URL) {
        // SwiftUI can deliver a geometry commit after session teardown closed its windows.
        guard !layoutSessionEnded else { return }
        var saved = layout
        saved.toolWindows = toolWindowStates
        saved.groupFractions = groupFractions
        layoutStore?.save(saved, for: workspaceURL)
    }

    func setSelectedSidebar(_ destination: SidebarDestination) {
        selectedSidebar = destination
    }

    func hideSidebar() {
        displayRequests = displayRequests.filter { $0.key.anchor != .left }
        hideToolWindows { $0.position.anchor == .left }
        persistContributionPreferences()
    }
}
