import Combine
import Foundation

/// Owns dock positions and visibility; feature modules retain their content and sessions.
// Note: .agents/notes/implemented/architecture/2026-10-12-tool-window-docking.md
@MainActor
final class WorkbenchFeatureModel: ObservableObject {
    enum ToolWindow: String, CaseIterable, Codable, Hashable, Sendable {
        case project, changes, pullRequests, search, database
        case gitLog, terminal, agent, databaseServices, references, problems, maven, mavenOutput, spring, run, tests, debug

        var sidebar: SidebarDestination? { SidebarDestination(rawValue: rawValue) }
        var rendererID: String? {
            switch self {
            case .gitLog: "git.log"
            case .terminal: "terminal.sessions"
            case .agent: "agent.conversation"
            case .database: "database.workspace"
            case .databaseServices: "database.services"
            case .problems: "language.problems"
            case .maven: "execution.maven"
            case .mavenOutput: "execution.maven.output"
            case .run: "execution.run"
            case .tests: "execution.tests"
            case .debug: "debug.session"
            default: nil
            }
        }
    }

    @Published private(set) var toolWindowStates = ToolWindow.allCases.enumerated().map {
        ToolWindowState(id: $0.element.rawValue,
                        position: DockPosition(anchor: $0.element.sidebar != nil && $0.element != .database ? .left :
                            (isRightDocked($0.element) ? .right : .bottom), group: .primary),
                        order: $0.offset, isVisible: $0.element == .project)
    }
    @Published private(set) var groupFractions: [String: Double] = [:]

    @Published var selectedSidebar: SidebarDestination = .project {
        didSet {
            setVisibility(ToolWindow(rawValue: selectedSidebar.rawValue)!, isVisible: true)
            guard oldValue != selectedSidebar else { return }
            sidebarSelectionHandler?(selectedSidebar)
        }
    }
    var isSidebarVisible: Bool { isVisible(ToolWindow(rawValue: selectedSidebar.rawValue)!) }
    @Published var isSettingsPresented = false
    @Published private(set) var requestedSettingsCategory: SettingsCategory = .general
    /// Increments with every request, so an open Settings window moves to the
    /// category again even when the same one was requested before and the user
    /// has since navigated away.
    @Published private(set) var settingsCategoryRequest = 0
    @Published var isCloneRepositoryPresented = false
    var activeToolWindow: ToolWindow? { activeTool(in: DockPosition(anchor: .bottom, group: .primary)) }
    var activeRightToolWindow: ToolWindow? { activeTool(in: DockPosition(anchor: .right, group: .primary)) }

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

    func state(for tool: ToolWindow) -> ToolWindowState {
        toolWindowStates.first { $0.id == tool.rawValue }!
    }

    func tools(in position: DockPosition) -> [ToolWindow] {
        toolWindowStates.filter { $0.position == position }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            .compactMap { ToolWindow(rawValue: $0.id) }
    }

    func activeTool(in position: DockPosition) -> ToolWindow? {
        tools(in: position).first { isVisible($0) }
    }

    func isVisible(_ toolWindow: ToolWindow) -> Bool { state(for: toolWindow).isVisible }

    func setVisibility(_ toolWindow: ToolWindow, isVisible: Bool) {
        let position = state(for: toolWindow).position
        var states = toolWindowStates
        for index in states.indices {
            if states[index].id == toolWindow.rawValue {
                states[index].isVisible = isVisible
            } else if isVisible && states[index].position == position {
                states[index].isVisible = false
            }
        }
        if states != toolWindowStates { toolWindowStates = states }
    }

    /// Commit one atomic move. Hover previews never mutate persisted layout.
    func move(_ tool: ToolWindow, to position: DockPosition, before target: ToolWindow? = nil) {
        guard target != tool else { return }
        var states = toolWindowStates
        guard let index = states.firstIndex(where: { $0.id == tool.rawValue }) else { return }
        let wasVisible = states[index].isVisible
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
    }

    func setGroupFraction(_ value: Double, for anchor: DockAnchor) {
        guard value.isFinite else { return }
        groupFractions[anchor.rawValue] = min(1, max(0, value))
    }

    func toggleVisibility(_ toolWindow: ToolWindow) {
        setVisibility(toolWindow, isVisible: !isVisible(toolWindow))
    }

    func hideBottomToolWindow() {
        var states = toolWindowStates
        for i in states.indices where states[i].position.anchor == .bottom { states[i].isVisible = false }
        toolWindowStates = states
    }

    func hideAllToolWindows() {
        var states = toolWindowStates
        for i in states.indices { states[i].isVisible = false }
        toolWindowStates = states
    }

    func presentSettings(category: SettingsCategory) {
        requestedSettingsCategory = category
        settingsCategoryRequest += 1
        isSettingsPresented = true
    }

    func reset() {
        hideAllToolWindows()
        selectedSidebar = .project
        isSettingsPresented = false
        requestedSettingsCategory = .general
        isCloneRepositoryPresented = false
    }

    func loadLayout(for workspaceURL: URL) -> WorkbenchLayout {
        let layout = layoutStore?.load(for: workspaceURL)
            ?? WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil)
        var states = Self().toolWindowStates
        var seen: Set<String> = []
        var visible: Set<DockPosition> = []
        for saved in layout.toolWindows ?? [] {
            guard let index = states.firstIndex(where: { $0.id == saved.id }),
                  seen.insert(saved.id).inserted else { continue }
            states[index] = saved
            // Opening a project must not launch its Agent panel or process.
            if saved.id == ToolWindow.agent.rawValue { states[index].isVisible = false }
            states[index].order = max(0, saved.order)
            if states[index].isVisible && !visible.insert(saved.position).inserted { states[index].isVisible = false }
        }
        // Missing records retain defaults, but cannot displace restored active windows.
        for index in states.indices where !seen.contains(states[index].id) && states[index].isVisible {
            if !visible.insert(states[index].position).inserted { states[index].isVisible = false }
        }
        toolWindowStates = states
        groupFractions = (layout.groupFractions ?? [:]).filter {
            DockAnchor(rawValue: $0.key) != nil && $0.value.isFinite && (0...1).contains($0.value)
        }
        return layout
    }

    func saveLayout(_ layout: WorkbenchLayout, for workspaceURL: URL) {
        var saved = layout
        saved.toolWindows = toolWindowStates
        saved.groupFractions = groupFractions
        layoutStore?.save(saved, for: workspaceURL)
    }

    func setSelectedSidebar(_ destination: SidebarDestination) {
        selectedSidebar = destination
    }

    func hideSidebar() {
        setVisibility(ToolWindow(rawValue: selectedSidebar.rawValue)!, isVisible: false)
    }
}
