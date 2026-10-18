import Foundation
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
    func repeatingASettingsCategoryRequestIsObservable() {
        // Settings links may request the category that was requested before,
        // after the user navigated elsewhere inside the open window.
        let model = WorkbenchFeatureModel()
        model.presentSettings(category: .project)
        let first = model.settingsCategoryRequest
        model.presentSettings(category: .project)
        #expect(model.requestedSettingsCategory == .project)
        #expect(model.settingsCategoryRequest == first + 1)
        #expect(model.isSettingsPresented)
    }

    @Test
    func pluginsOpenInSettingsWhileARightToolRemainsVisible() {
        let model = WorkbenchFeatureModel()
        model.setVisibility(.database, isVisible: true)

        model.presentSettings(category: .plugins)

        #expect(model.isSettingsPresented)
        #expect(model.requestedSettingsCategory == .plugins)
        #expect(model.isVisible(.database))
    }

    @Test
    func rightDockedToolDoesNotReplaceBottomTools() {
        let model = WorkbenchFeatureModel()
        model.setVisibility(.terminal, isVisible: true)
        model.setVisibility(.database, isVisible: true)
        #expect(model.activeToolWindow == .terminal)
        #expect(model.isVisible(.database))

        model.setVisibility(.run, isVisible: true)
        #expect(model.isVisible(.database))
        #expect(model.isVisible(.run))
        #expect(!model.isVisible(.terminal))

        model.setVisibility(.debug, isVisible: true)
        #expect(model.isVisible(.database))
        #expect(model.isVisible(.debug))
    }

    @Test
    func rightDockedToolAndBuildOutputCloseIndependently() {
        let model = WorkbenchFeatureModel()
        model.setVisibility(.database, isVisible: true)
        model.setVisibility(.buildOutput, isVisible: true)
        model.setVisibility(.buildOutput, isVisible: false)
        #expect(model.isVisible(.database))
        #expect(model.activeToolWindow == nil)

        model.setVisibility(.buildOutput, isVisible: true)
        model.toggleVisibility(.database)
        #expect(!model.isVisible(.database))
        #expect(model.isVisible(.buildOutput))

        model.toggleVisibility(.database)
        model.hideAllToolWindows()
        #expect(!model.isVisible(.database))
        #expect(model.activeToolWindow == nil)
    }

    @Test
    func agentDocksBesideTheEditorAndSharesTheRightSlotWithDatabase() {
        // The Agent conversation must keep the editor visible, so it takes the
        // right dock instead of the bottom tool window. Database and Agent share
        // that dock, and neither replaces a bottom tool window.
        let model = WorkbenchFeatureModel()
        model.setVisibility(.terminal, isVisible: true)
        model.setVisibility(.agent, isVisible: true)
        #expect(model.isVisible(.agent))
        #expect(model.activeToolWindow == .terminal)
        #expect(model.activeRightToolWindow == .agent)

        model.setVisibility(.database, isVisible: true)
        #expect(model.isVisible(.database))
        #expect(!model.isVisible(.agent))
        #expect(model.isVisible(.terminal))

        model.toggleVisibility(.agent)
        #expect(model.isVisible(.agent))
        #expect(!model.isVisible(.database))

        model.hideBottomToolWindow()
        #expect(model.isVisible(.agent))

        model.reset()
        #expect(model.activeRightToolWindow == nil)
    }

    @Test
    func workspaceResetClearsRightAndBottomAreas() {
        let model = WorkbenchFeatureModel()
        model.setVisibility(.database, isVisible: true)
        model.setVisibility(.buildOutput, isVisible: true)
        model.reset()
        #expect(!model.isVisible(.database))
        #expect(!model.isVisible(.buildOutput))
    }

    @Test
    func languageNavigationReplacesBottomToolWithoutClosingRightDock() {
        let store = WorkbenchFeatureModelTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        model.workbenchFeature.setVisibility(.database, isVisible: true)
        model.isTerminalVisible = true

        model.presentLanguageNavigationResults(.references)

        #expect(model.workbenchFeature.isVisible(.database))
        #expect(model.isReferencesVisible)
        #expect(!model.isTerminalVisible)

        model.isTerminalVisible = true
        model.presentLanguageNavigationResults(.implementations)

        #expect(model.workbenchFeature.isVisible(.database))
        #expect(model.isImplementationChooserVisible)
        #expect(!model.isReferencesVisible)
        #expect(!model.isTerminalVisible)
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

    @Test
    func hidingSidebarPreservesSelectionAndSelectingItAgainRestoresThePane() {
        let model = WorkbenchFeatureModel()

        model.hideSidebar()
        #expect(!model.isSidebarVisible)
        #expect(model.selectedSidebar == .project)

        model.setSelectedSidebar(.project)
        #expect(model.isSidebarVisible)

        model.hideSidebar()
        model.setSelectedSidebar(.search)
        #expect(model.isSidebarVisible)
        #expect(model.selectedSidebar == .search)
    }
}

private final class WorkbenchFeatureModelTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
