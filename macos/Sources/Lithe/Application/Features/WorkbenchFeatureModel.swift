import Combine
import Foundation

/// Owns the right dock and the bottom tool window. Each area shows at most one
/// tool window, and the two areas open and close independently of each other.
///
/// AppModel keeps compatibility accessors for existing callers while new
/// workbench code can depend on this focused state model directly.
@MainActor
final class WorkbenchFeatureModel: ObservableObject {
    enum ToolWindow: Equatable {
        case gitLog
        case terminal
        case agent
        case references
        case problems
        case maven
        case mavenOutput
        case spring
        case run
        case tests
        case debug
    }

    @Published var selectedSidebar: SidebarDestination = .project {
        didSet {
            guard oldValue != selectedSidebar else { return }
            sidebarSelectionHandler?(selectedSidebar)
        }
    }
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
        case .maven, .agent: true
        default: false
        }
    }

    func isVisible(_ toolWindow: ToolWindow) -> Bool {
        Self.isRightDocked(toolWindow)
            ? activeRightToolWindow == toolWindow
            : activeToolWindow == toolWindow
    }

    func setVisibility(_ toolWindow: ToolWindow, isVisible: Bool) {
        if Self.isRightDocked(toolWindow) {
            if isVisible {
                guard activeRightToolWindow != toolWindow else { return }
                activeRightToolWindow = toolWindow
            } else if activeRightToolWindow == toolWindow {
                activeRightToolWindow = nil
            }
            return
        }
        if isVisible {
            guard activeToolWindow != toolWindow else { return }
            activeToolWindow = toolWindow
        } else if activeToolWindow == toolWindow {
            activeToolWindow = nil
        }
    }

    func toggleVisibility(_ toolWindow: ToolWindow) {
        setVisibility(toolWindow, isVisible: !isVisible(toolWindow))
    }

    func hideBottomToolWindow() {
        activeToolWindow = nil
    }

    func hideAllToolWindows() {
        hideBottomToolWindow()
        activeRightToolWindow = nil
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
        layoutStore?.load(for: workspaceURL)
            ?? WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil)
    }

    func saveLayout(_ layout: WorkbenchLayout, for workspaceURL: URL) {
        layoutStore?.save(layout, for: workspaceURL)
    }

    func setSelectedSidebar(_ destination: SidebarDestination) {
        selectedSidebar = destination
    }
}
