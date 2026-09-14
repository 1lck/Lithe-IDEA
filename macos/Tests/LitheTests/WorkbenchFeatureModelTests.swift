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
    func mavenNavigationDoesNotReplaceBottomTools() {
        let model = WorkbenchFeatureModel()
        model.setVisibility(.terminal, isVisible: true)
        model.setVisibility(.maven, isVisible: true)
        #expect(model.activeToolWindow == .terminal)
        #expect(model.isVisible(.maven))

        model.setVisibility(.run, isVisible: true)
        #expect(model.isVisible(.maven))
        #expect(model.isVisible(.run))
        #expect(!model.isVisible(.terminal))

        model.setVisibility(.debug, isVisible: true)
        #expect(model.isVisible(.maven))
        #expect(model.isVisible(.debug))
    }

    @Test
    func mavenNavigationAndOutputCloseIndependently() {
        let model = WorkbenchFeatureModel()
        model.setVisibility(.maven, isVisible: true)
        model.setVisibility(.mavenOutput, isVisible: true)
        model.setVisibility(.mavenOutput, isVisible: false)
        #expect(model.isVisible(.maven))
        #expect(model.activeToolWindow == nil)

        model.setVisibility(.mavenOutput, isVisible: true)
        model.toggleVisibility(.maven)
        #expect(!model.isVisible(.maven))
        #expect(model.isVisible(.mavenOutput))

        model.toggleVisibility(.maven)
        model.hideAllToolWindows()
        #expect(!model.isVisible(.maven))
        #expect(model.activeToolWindow == nil)
    }

    @Test
    func workspaceResetClearsBothMavenAreas() {
        let model = WorkbenchFeatureModel()
        model.setVisibility(.maven, isVisible: true)
        model.setVisibility(.mavenOutput, isVisible: true)
        model.reset()
        #expect(!model.isVisible(.maven))
        #expect(!model.isVisible(.mavenOutput))
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
