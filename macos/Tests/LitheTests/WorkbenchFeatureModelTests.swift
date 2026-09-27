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
    func agentDocksBesideTheEditorAndSharesTheRightSlotWithMaven() {
        // The Agent conversation must keep the editor visible, so it takes the
        // right dock instead of the bottom tool window. Maven and Agent share
        // that dock, and neither replaces a bottom tool window.
        let model = WorkbenchFeatureModel()
        model.setVisibility(.terminal, isVisible: true)
        model.setVisibility(.agent, isVisible: true)
        #expect(model.isVisible(.agent))
        #expect(model.activeToolWindow == .terminal)
        #expect(model.activeRightToolWindow == .agent)

        model.setVisibility(.maven, isVisible: true)
        #expect(model.isVisible(.maven))
        #expect(!model.isVisible(.agent))
        #expect(model.isVisible(.terminal))

        model.toggleVisibility(.agent)
        #expect(model.isVisible(.agent))
        #expect(!model.isVisible(.maven))

        model.hideBottomToolWindow()
        #expect(model.isVisible(.agent))

        model.reset()
        #expect(model.activeRightToolWindow == nil)
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
    func languageNavigationReplacesBottomToolWithoutClosingMavenDock() {
        let store = WorkbenchFeatureModelTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        model.isMavenVisible = true
        model.isTerminalVisible = true

        model.presentLanguageNavigationResults(.references)

        #expect(model.isMavenVisible)
        #expect(model.isReferencesVisible)
        #expect(!model.isTerminalVisible)

        model.isTerminalVisible = true
        model.presentLanguageNavigationResults(.implementations)

        #expect(model.isMavenVisible)
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
}

private final class WorkbenchFeatureModelTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
