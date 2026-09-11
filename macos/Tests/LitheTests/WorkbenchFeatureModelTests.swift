import Testing
@testable import Lithe

@Suite("Workbench feature model")
@MainActor
struct WorkbenchFeatureModelTests {
    @Test
    func toolWindowsAreMutuallyExclusive() {
        let model = WorkbenchFeatureModel()

        model.setVisibility(.terminal, isVisible: true)
        #expect(model.isVisible(.terminal))

        model.setVisibility(.debug, isVisible: true)
        #expect(model.isVisible(.debug))
        #expect(!model.isVisible(.terminal))

        model.setVisibility(.debug, isVisible: false)
        #expect(model.activeToolWindow == nil)
    }

    @Test
    func sidebarSelectionNotifiesOnlyWhenSelectionChanges() {
        let model = WorkbenchFeatureModel()
        var selections: [SidebarDestination] = []
        model.configure { selections.append($0) }

        model.selectedSidebar = .project
        model.selectedSidebar = .changes
        model.selectedSidebar = .changes

        #expect(selections == [.changes])
        #expect(model.selectedSidebar == .changes)
    }
}
