import Combine
import Foundation

/// Owns the workbench selection and the mutually exclusive bottom tool window.
///
/// AppModel keeps compatibility accessors for existing callers while new
/// workbench code can depend on this focused state model directly.
@MainActor
final class WorkbenchFeatureModel: ObservableObject {
    enum ToolWindow: Equatable {
        case gitLog
        case terminal
        case references
        case problems
        case maven
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
    @Published var isCloneRepositoryPresented = false
    @Published private(set) var activeToolWindow: ToolWindow?

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

    func isVisible(_ toolWindow: ToolWindow) -> Bool {
        activeToolWindow == toolWindow
    }

    func setVisibility(_ toolWindow: ToolWindow, isVisible: Bool) {
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

    func hideAllToolWindows() {
        activeToolWindow = nil
    }

    func presentSettings(category: SettingsCategory) {
        requestedSettingsCategory = category
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
