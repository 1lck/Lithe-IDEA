import Combine
import AppKit
import SwiftUI
import Foundation
import Testing
import LitheModuleAPI
import LitheApplicationKernel
import LitheCoreContracts
@testable import Lithe

@Suite("Workbench contribution host")
@MainActor
struct WorkbenchContributionHostTests {
    private func descriptor() throws -> DeclarativePluginDescriptor {
        let data = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/hello-lithe.plugin.json"))
        return try DeclarativePluginTestSupport.operations.validate(manifest: data)
    }

    @Test func registeredPluginPreservesSecondaryDockAndLayoutThroughSessionCleanup() throws {
        let suite = "lithe-contribution-dock-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchLayoutStore(store: MacUserDefaultsStore(defaults: defaults))
        let workspace = URL(fileURLWithPath: "/fixture/registered-dock")
        let declaration = try #require(descriptor().pluginManifest.modules.first)
        let contribution = try #require(declaration.contributions.first { $0.kind == .toolWindow })
        let window = WorkbenchFeatureModel.ToolWindow(rawValue: contribution.id)
        let owners: [ModuleID: [ModuleContribution]] = [
            .workspace: BuiltInModuleCatalog.contributions(for: .workspace),
            declaration.manifest.id: declaration.contributions
        ]
        let workbench = WorkbenchFeatureModel(layoutStore: store)
        workbench.reconcileContributions(owners)
        _ = workbench.loadLayout(for: workspace)
        workbench.setVisibility(.agent, isVisible: true)
        let position = DockPosition(anchor: .right, group: .secondary)
        workbench.move(window, to: position)
        workbench.setVisibility(window, isVisible: true)
        #expect(workbench.isVisible(.agent))
        #expect(workbench.activeTool(in: position) == window)
        #expect(workbench.contributions(declaration.contributions, at: .rightSidebar).contains(contribution))
        workbench.customizeContribution(contribution.id, isHidden: true)
        #expect(!workbench.isVisible(window))
        #expect(workbench.isVisible(.agent))
        workbench.customizeContribution(contribution.id, isHidden: false)
        workbench.setVisibility(window, isVisible: true)
        workbench.setGroupFraction(0.7, for: .right)
        workbench.saveLayout(.init(sidebarWidth: 310, topPaneHeight: 280), for: workspace)
        let saved = store.load(for: workspace)
        workbench.endLayoutSession()
        // A delayed SwiftUI geometry commit must not save cleanup as the user's layout.
        workbench.saveLayout(.init(sidebarWidth: 310, topPaneHeight: 280), for: workspace)
        #expect(store.load(for: workspace).toolWindows == saved.toolWindows)
        let restored = WorkbenchFeatureModel(layoutStore: store)
        restored.reconcileContributions(owners)
        _ = restored.loadLayout(for: workspace)
        #expect(restored.activeTool(in: position) == window)
        #expect(!restored.isVisible(.agent), "Opening a project must not relaunch the Agent panel")
        #expect(restored.groupFractions["right"] == 0.7)
        #expect(restored.state(for: window).position == position)
        restored.resetContributionPreferences()
        #expect(restored.isVisible(.project))
        #expect(restored.state(for: window).position == .init(anchor: .right, group: .primary))
    }

    @Test func dataOnlyPluginRegistersAllUIWithoutAWorkbenchBranch() async throws {
        let descriptor = try descriptor()
        let declaration = try #require(descriptor.pluginManifest.modules.first)
        #expect(descriptor.languageServers.isEmpty)
        #expect(declaration.contributions.filter { $0.kind == .toolWindow }.count == 1)
        #expect(Set(declaration.contributions.filter { $0.kind == .command }.map(\.placement)) == [.commandPalette, .toolbar, .menu])
        let catalog = try ValidatedPluginCatalog(
            manifests: BuiltInPluginCatalog.manifests + [descriptor.pluginManifest],
            hostVersion: BuiltInPluginCatalog.hostVersion
        )
        let registry = try WorkbenchModuleUIComposition.registry(for: catalog)
        try registry.validate(contributions: declaration.contributions)
        let window = try #require(declaration.contributions.first { $0.kind == .toolWindow })
        #expect(registry.renderer(for: window) != nil)

        let runtime = ModuleRuntime()
        try await WorkbenchTestScope.withCleanup({ await runtime.shutdownAll() }) { scope in
            try runtime.register(ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
                DeclarativeWorkbenchModule(declaration: declaration)
            })
            #expect(runtime.snapshots().first?.isInstantiated == false)
            #expect(runtime.availableContributions()[declaration.manifest.id] == declaration.contributions)
            try await scope.run("module activation") { _ = try await runtime.activate(declaration.manifest.id) }
            #expect(runtime.contributions()[declaration.manifest.id]?.sorted { $0.id < $1.id } == declaration.contributions.sorted { $0.id < $1.id })
            try await scope.run("module enablement") { try await runtime.setEnabled(false, for: declaration.manifest.id) }
            #expect(runtime.availableContributions().isEmpty)
            #expect(runtime.contributions().isEmpty)
            try await scope.run("module enablement") { try await runtime.setEnabled(true, for: declaration.manifest.id) }
            #expect(runtime.availableContributions()[declaration.manifest.id] == declaration.contributions)
        }
    }

    @Test func nativeToolbarEntriesShareLayoutPreferencesAndModuleAvailability() async throws {
        let suite = "lithe-native-toolbar-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        let workspace = URL(fileURLWithPath: "/fixture/native-toolbar")
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            model.workspaceSessionCoordinator.beginWorkspace(at: workspace)
            _ = model.loadWorkbenchLayout(for: workspace)
            let run = try #require(model.workbenchContributions.first { $0.id == "workbench.toolbar.run" })
            #expect(model.workbenchUIRegistry.state(for: run, model: model).isEnabled)
            #expect(model.registeredContributions(at: .toolbar).map(\.id) == ["workbench.toolbar.run", "workbench.toolbar.debug"])
            model.workbenchFeature.moveContribution("workbench.toolbar.debug", earlier: true)
            model.workbenchFeature.customizeContribution(run.id, isHidden: true)
            model.saveWorkbenchLayout(WorkbenchLayout(sidebarWidth: 444, topPaneHeight: 333), for: workspace)
            let restored = WorkbenchFeatureModel(layoutStore: WorkbenchLayoutStore(store: store))
            restored.reconcileContributions(container.services.moduleRuntime.availableContributions())
            _ = restored.loadLayout(for: workspace)
            #expect(restored.contributionPreferences[run.id]?.isHidden == true)
            #expect(restored.contributions(model.workbenchContributions, at: .toolbar).first?.id == "workbench.toolbar.debug")
            try await scope.run("disable execution toolbar owner") {
                try await container.services.moduleRuntime.setEnabled(false, for: .debug)
                try await container.services.moduleRuntime.setEnabled(false, for: .execution)
            }
            model.showContributionEntry(run)
            #expect(model.workbenchFeature.contributionPreferences[run.id]?.isHidden == false)
            #expect(!model.workbenchUIRegistry.state(for: run, model: model).isEnabled)
            #expect(model.workbenchUIRegistry.state(forActionID: "run", model: model).isEnabled == false)
            #expect(model.workbenchUIRegistry.state(forActionID: "debug", model: model).isEnabled == false)
            #expect(LitheActionRegistry.actions(for: model).first { $0.id == "run" }?.isEnabled == false)
            #expect(!model.canPerformShortcutCommand(id: "run"))
            model.workbenchUIRegistry.perform(run, model: model)
            #expect(model.runFeatureIfActive == nil)
            #expect(container.services.moduleRuntime.snapshots()
                .filter { [.execution, .debug].contains($0.manifest.id) }.allSatisfy { !$0.isInstantiated })
            model.workbenchFeature.resetContributionPreferences()
            #expect(model.workbenchFeature.contributionPreferences.isEmpty)
        }
    }

    @Test(arguments: [ModuleContributionPlacement.toolbar, .menu])
    func restoringCommandEntriesNeverExecutesTheirActions(placement: ModuleContributionPlacement) async throws {
        let suite = "lithe-restore-entry-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let command = ModuleContribution(id: "org.example.entry.command", kind: .command, title: "Fixture",
            placement: placement, actionID: "org.example.entry.command")
        let declaration = PluginModuleDeclaration(
            manifest: .init(id: .init("org.example.entry"), displayName: "Entry", scope: .workspace),
            contributions: [command])
        try container.services.moduleRuntime.register(ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
            DeclarativeWorkbenchModule(declaration: declaration)
        })
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            var invocations = 0
            model.workbenchUIRegistry = try WorkbenchModuleUIRegistry(registrations: WorkbenchModuleUIComposition.registrations + [
                .init(contributions: [command], actions: [.init(id: command.actionID!, perform: { _ in invocations += 1 })])])
            model.workbenchFeature.customizeContribution(command.id, isHidden: true)
            #expect(!model.registeredContributions(at: placement).contains(command))
            let stale = ModuleContribution(id: command.id, kind: .command, title: "Old", placement: placement, actionID: command.actionID)
            model.showContributionEntry(stale)
            #expect(model.workbenchFeature.contributionPreferences[command.id]?.isHidden == true)
            model.showContributionEntry(command)
            #expect(model.registeredContributions(at: placement).contains(command))
            #expect(invocations == 0)
            model.workbenchUIRegistry.perform(command, model: model)
            #expect(invocations == 1)
        }
    }

    @Test(arguments: ["left", "bottom", "right"])
    func pluginDefaultDockIsPreservedThroughValidationAndHostRegistration(placement: String) throws {
        var manifest = try #require(JSONSerialization.jsonObject(with: descriptor().normalizedManifest) as? [String: Any])
        var ui = try #require(manifest["ui"] as? [String: Any])
        var windows = try #require(ui["toolWindows"] as? [[String: Any]])
        windows[0]["placement"] = placement
        ui["toolWindows"] = windows
        manifest["ui"] = ui
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: JSONSerialization.data(withJSONObject: manifest))
        let declaration = try #require(descriptor.pluginManifest.modules.first)
        let contribution = try #require(declaration.contributions.first { $0.kind == .toolWindow })
        let expected: ModuleContributionPlacement = placement == "left" ? .leftSidebar : (placement == "right" ? .rightSidebar : .activityBar)
        #expect(contribution.placement == expected)
        let workbench = WorkbenchFeatureModel()
        workbench.reconcileContributions([declaration.manifest.id: declaration.contributions])
        let window = WorkbenchFeatureModel.ToolWindow(rawValue: contribution.id)
        workbench.setVisibility(window, isVisible: true)
        #expect(workbench.isVisible(window))
        #expect(workbench.contributions(declaration.contributions, at: expected).contains(contribution))
        #expect((expected == .leftSidebar ? workbench.activeLeftToolWindow : (expected == .rightSidebar ? workbench.activeRightToolWindow : workbench.activeToolWindow)) == window)
    }

    @Test(arguments: ["toggle-terminal", "toggle-problems", "toggle-git-log", "toggle-run", "toggle-tests", "toggle-debug", "spring-endpoints"])
    func nativeWindowCommandsReuseRegisteredActionsAndCheckedState(id: String) async throws {
        let suite = "lithe-native-window-command-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            model.workspaceSessionCoordinator.beginWorkspace(at: URL(fileURLWithPath: "/fixture/native-window-command"))
            let window = try #require(LitheCommandCatalog.toolWindow(for: id))
            let contribution = try #require(model.workbenchContributions.first { $0.id == window.rawValue })
            var invocations = 0
            model.workbenchUIRegistry = try WorkbenchModuleUIRegistry(registrations: [.init(actions:
                WorkbenchModuleUIComposition.applicationActions + [.init(id: contribution.actionID!, perform: { model in
                    invocations += 1
                    model.workbenchFeature.toggleVisibility(window)
                })])])
            model.workbenchFeature.setVisibility(window, isVisible: false)
            model.performShortcutCommand(id: id)
            #expect(invocations == 1 && model.workbenchFeature.isVisible(window))
            let action = try #require(LitheActionRegistry.actions(for: model).first { $0.id == id })
            #expect(action.isChecked)
            action.perform()
            #expect(invocations == 2 && !model.workbenchFeature.isVisible(window))
        }
    }

    @Test func legacySidebarNamesAndPluginIDsRoundTrip() throws {
        let names: [(String, String)] = [("project", "workspace.project"), ("changes", "git.changes"),
            ("search", "search.workspace"), ("pullRequests", "github.pull-requests"), ("org.example.info", "org.example.info")]
        for (legacy, id) in names {
            #expect(try #require(SidebarDestination(rawValue: legacy)).contributionID == id)
            #expect(SidebarDestination(contributionID: id).rawValue == legacy)
        }
        #expect(SidebarDestination(rawValue: "") == nil)
    }

    @Test func leftSidebarCustomizationSurvivesGeometryAndSessionCleanup() throws {
        let suite = "lithe-left-layout-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchLayoutStore(store: MacUserDefaultsStore(defaults: defaults))
        let workspace = URL(fileURLWithPath: "/fixture/left-layout")
        let owners: [ModuleID: [ModuleContribution]] = [.workspace: BuiltInModuleCatalog.contributions(for: .workspace),
            .git: BuiltInModuleCatalog.contributions(for: .git), .search: BuiltInModuleCatalog.contributions(for: .search)]
        let catalog = owners.values.flatMap { $0 }
        let model = WorkbenchFeatureModel(layoutStore: store)
        model.reconcileContributions(owners)
        _ = model.loadLayout(for: workspace)
        model.moveContribution("search.workspace", earlier: true)
        #expect(model.contributions(catalog, at: .leftSidebar).map(\.id) == ["workspace.project", "git.changes", "search.workspace", "github.pull-requests"])
        model.setSelectedSidebar(.search)
        model.hideSidebar()
        store.save(WorkbenchLayout(sidebarWidth: 444, topPaneHeight: 222), for: workspace)
        model.endLayoutSession()
        let restored = WorkbenchFeatureModel(layoutStore: store)
        restored.reconcileContributions(owners)
        let layout = restored.loadLayout(for: workspace)
        #expect(layout.sidebarWidth == 444)
        #expect(!restored.isSidebarVisible)
        #expect(restored.selectedSidebar == .search)
        #expect(restored.contributions(catalog, at: .leftSidebar).map(\.id) == ["workspace.project", "git.changes", "search.workspace", "github.pull-requests"])
        restored.setSelectedSidebar(.search)
        restored.customizeContribution("search.workspace", isHidden: true)
        #expect(!restored.isSidebarVisible)
        #expect(!restored.contributions(catalog, at: .leftSidebar).contains { $0.id == "search.workspace" })
        restored.setSelectedSidebar(.search)
        #expect(restored.isVisible(.search))
        #expect(restored.contributionPreferences["search.workspace"]?.isHidden == false)
        restored.resetContributionPreferences()
        #expect(restored.isVisible(.project))
        #expect(restored.contributions(catalog, at: .leftSidebar).map(\.id) == ["workspace.project", "git.changes", "github.pull-requests", "search.workspace"])
    }

    @Test(arguments: ["workspace.project", "git.changes", "search.workspace", "org.example.info"])
    func toolWindowsUseAllThreeSlotsWithoutRecreatingModules(id: String) {
        let window = WorkbenchFeatureModel.ToolWindow(rawValue: id)
        let owner = ModuleID("org.example.owner")
        let declaration = ModuleContribution(id: id, kind: .toolWindow, title: id, placement: .leftSidebar)
        let model = WorkbenchFeatureModel()
        model.reconcileContributions([owner: [declaration]])
        model.setVisibility(.terminal, isVisible: true)
        model.setVisibility(.database, isVisible: true)
        model.setVisibility(window, isVisible: true)
        #expect(model.activeLeftToolWindow == window)
        #expect(model.activeToolWindow == .terminal)
        #expect(model.activeRightToolWindow == .database)
        model.customizeContribution(id, placement: .rightSidebar)
        #expect(model.activeLeftToolWindow == nil)
        #expect(model.activeRightToolWindow == window)
        #expect(model.activeToolWindow == .terminal)
        model.setVisibility(window, isVisible: false)
        #expect(model.activeRightToolWindow == nil)
        #expect(model.activeToolWindow == .terminal)
        model.setVisibility(window, isVisible: true)
        model.customizeContribution(id, placement: .activityBar)
        #expect(model.activeRightToolWindow == nil)
        #expect(model.activeToolWindow == window)
        model.customizeContribution(id, placement: .leftSidebar)
        #expect(model.activeToolWindow == nil)
        #expect(model.activeLeftToolWindow == window)
        model.releaseContributions(for: owner)
        #expect(!model.isSidebarVisible)
        #expect(model.contributionPreferences[id]?.placement == .leftSidebar)
    }

    @Test func removedPluginSessionSelectionFallsBackWithoutOpeningAnUnknownWindow() throws {
        let model = WorkbenchFeatureModel()
        model.reconcileContributions([.workspace: BuiltInModuleCatalog.contributions(for: .workspace)])
        model.selectedSidebar = try #require(SidebarDestination(rawValue: "org.removed.info"))
        #expect(model.isVisible(.project))
        #expect(model.selectedSidebar == .project)
        #expect(model.activeToolWindow == nil && model.activeRightToolWindow == nil)
    }

    @Test func oldGeometryLayoutsKeepTheRestoredSidebarSelection() throws {
        let suite = "lithe-old-left-layout-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchLayoutStore(store: MacUserDefaultsStore(defaults: defaults))
        let workspace = URL(fileURLWithPath: "/fixture/old-left-layout")
        store.save(WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil), for: workspace)
        let model = WorkbenchFeatureModel(layoutStore: store)
        model.reconcileContributions([.search: BuiltInModuleCatalog.contributions(for: .search)])
        model.selectedSidebar = try #require(SidebarDestination(rawValue: "search"))
        _ = model.loadLayout(for: workspace)
        #expect(model.isVisible(.search))
        #expect(model.selectedSidebar.rawValue == "search")
    }

    @Test func unavailableLeftOwnerClosesContentWithoutErasingSavedVisibility() throws {
        let suite = "lithe-left-release-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchLayoutStore(store: MacUserDefaultsStore(defaults: defaults))
        let workspace = URL(fileURLWithPath: "/fixture/left-release")
        let owners: [ModuleID: [ModuleContribution]] = [.search: BuiltInModuleCatalog.contributions(for: .search)]
        let model = WorkbenchFeatureModel(layoutStore: store)
        model.reconcileContributions(owners)
        _ = model.loadLayout(for: workspace)
        model.setVisibility(.search, isVisible: true)
        model.releaseContributions(for: .search)
        model.reconcileContributions([:])
        #expect(!model.isSidebarVisible)
        #expect(store.load(for: workspace).sidebarToolWindowID == "search.workspace")
        #expect(store.load(for: workspace).isSidebarVisible == true)
        let restored = WorkbenchFeatureModel(layoutStore: store)
        restored.reconcileContributions(owners)
        _ = restored.loadLayout(for: workspace)
        #expect(restored.isVisible(.search))
    }

    @Test(arguments: [false, true])
    func restoredPluginDoesNotReopenAfterTheUserClosesItDuringActivation(selectAnotherWindow: Bool) async throws {
        let suite = "lithe-left-restore-race-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let declaration = PluginModuleDeclaration(
            manifest: ModuleManifest(id: ModuleID("org.example.restore"), displayName: "Restore", scope: .workspace),
            contributions: [ModuleContribution(id: "org.example.restore.info", kind: .toolWindow,
                title: "Info", placement: .leftSidebar, actionID: "org.example.restore.toggle",
                rendererID: "org.example.restore.info", text: "Fixture")])
        let started = TestGate()
        let release = TestGate()
        defer { release.open() }
        try container.services.moduleRuntime.register(ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
            GatedWorkbenchTestModule(declaration: declaration, started: started, release: release)
        })
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            defer { release.open() }
            model.workbenchUIRegistry = try WorkbenchModuleUIRegistry(registrations: WorkbenchModuleUIComposition.registrations + [
                WorkbenchModuleUIRegistry.declarativeRegistration(declaration)])
            model.workspaceSessionCoordinator.beginWorkspace(at: URL(fileURLWithPath: "/fixture/restore-race"))
            let window = WorkbenchFeatureModel.ToolWindow(rawValue: declaration.contributions[0].id)
            model.workbenchFeature.setVisibility(window, isVisible: true)
            model.restoreRegisteredToolWindows([window.rawValue])
            let pending = model.contributionActivationTasks[window.rawValue]
            defer { pending?.cancel() }
            #expect(await started.waitUntilOpen(), "Restored window never started its module")
            if selectAnotherWindow { model.workbenchFeature.setVisibility(.project, isVisible: true) }
            else { model.workbenchFeature.setVisibility(window, isVisible: false) }
            release.open()
            try await scope.run("window activation") { await pending?.value }
            #expect(!model.workbenchFeature.isVisible(window))
            #expect(model.contributionActivationTasks.isEmpty)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func firstOpenRespectsLatestDockSelection(useShow: Bool, sameGroup: Bool) async throws {
        let suite = "lithe-left-restore-race-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let declaration = PluginModuleDeclaration(
            manifest: ModuleManifest(id: ModuleID("org.example.restore"), displayName: "Restore", scope: .workspace),
            contributions: [ModuleContribution(id: "org.example.restore.info", kind: .toolWindow,
                title: "Info", placement: .leftSidebar, actionID: "org.example.restore.toggle",
                rendererID: "org.example.restore.info", text: "Fixture")])
        let started = TestGate()
        let release = TestGate()
        defer { release.open() }
        try container.services.moduleRuntime.register(ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
            GatedWorkbenchTestModule(declaration: declaration, started: started, release: release)
        })
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            defer { release.open() }
            model.workbenchUIRegistry = try WorkbenchModuleUIRegistry(registrations: WorkbenchModuleUIComposition.registrations + [
                WorkbenchModuleUIRegistry.declarativeRegistration(declaration)])
            model.workspaceSessionCoordinator.beginWorkspace(at: URL(fileURLWithPath: "/fixture/restore-race"))
            let window = WorkbenchFeatureModel.ToolWindow(rawValue: declaration.contributions[0].id)
            if !sameGroup { model.workbenchFeature.move(.project, to: .init(anchor: .left, group: .secondary)) }
            let contribution = declaration.contributions[0]
            if useShow { model.showContributionEntry(contribution) }
            else { model.workbenchUIRegistry.perform(contribution, model: model) }
            let pending = model.contributionActivationTasks[window.rawValue]
            defer { pending?.cancel() }
            #expect(await started.waitUntilOpen(), "Restored window never started its module")
            model.workbenchFeature.setVisibility(.project, isVisible: true)
            release.open()
            try await scope.run("window activation") { await pending?.value }
            #expect(model.workbenchFeature.isVisible(window) == !sameGroup)
            #expect(model.workbenchFeature.isVisible(.project))
            #expect(model.contributionActivationTasks.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func concurrentWindowCommandsShareStateAndOneModuleActivation(disableModule: Bool) async throws {
        let suite = "lithe-ui-action-state-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let owner = ModuleID("org.example.actions")
        let windows = ["first", "second"].map { name in
            let id = owner.rawValue + "." + name
            return ModuleContribution(id: id, kind: .toolWindow, title: name,
                placement: name == "first" ? .leftSidebar : .rightSidebar,
                actionID: id + ".toggle", rendererID: id, text: "Fixture")
        }
        let commands = windows.flatMap { window in
            [ModuleContributionPlacement.toolbar, .menu, .commandPalette].map { placement in
                ModuleContribution(id: window.id + ".open." + placement.rawValue, kind: .command,
                    title: window.title, placement: placement, actionID: window.id + ".open",
                    visibility: ["toolWindowID": window.id])
            }
        }
        let declaration = PluginModuleDeclaration(
            manifest: ModuleManifest(id: owner, displayName: "Actions", scope: .workspace),
            contributions: windows + commands)
        let started = TestGate(), release = TestGate(), joined = TestGate()
        defer { release.open() }
        var constructions = 0
        try container.services.moduleRuntime.register(ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
            constructions += 1
            return GatedWorkbenchTestModule(declaration: declaration, started: started, release: release)
        })
        let observer = container.services.moduleRuntime.observeEvents {
            if $0.source == owner && $0.name == "module.activation-joined" { joined.open() }
        }
        defer { container.services.moduleRuntime.removeEventObserver(observer) }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            defer { release.open() }
            model.workbenchUIRegistry = try WorkbenchModuleUIRegistry(registrations: WorkbenchModuleUIComposition.registrations + [
                WorkbenchModuleUIRegistry.declarativeRegistration(declaration)])
            #expect(model.registeredContributions(at: .toolbar).isEmpty)
            model.workspaceSessionCoordinator.beginWorkspace(at: URL(fileURLWithPath: "/fixture/action-state"))
            let first = commands[0], second = commands[3]
            let staleAction = LitheActionRegistry.actions(for: model).first { $0.id == first.actionID }
            #expect(staleAction != nil)
            model.workbenchUIRegistry.perform(first, model: model)
            let firstTask = model.contributionActivationTasks[windows[0].id]
            defer { firstTask?.cancel() }
            #expect(await started.waitUntilOpen(), "First module activation did not reach the gate")
            for command in commands.prefix(3) {
                let state = model.workbenchUIRegistry.state(for: command, model: model)
                #expect(state.isVisible && !state.isEnabled && state.isPending)
            }
            #expect(LitheActionRegistry.actions(for: model).first { $0.id == first.actionID }?.isEnabled == false)
            #expect(model.workbenchUIRegistry.state(for: windows[0], model: model).isEnabled)
            model.searchSessionFeature.isSearchEverywhereVisible = true
            if let staleAction { model.performSearchEverywhereAction(staleAction) }
            #expect(model.isSearchEverywhereVisible)
            model.workbenchUIRegistry.perform(second, model: model)
            let secondTask = model.contributionActivationTasks[windows[1].id]
            defer { secondTask?.cancel() }
            #expect(await joined.waitUntilOpen(), "Second window did not join the first module activation")
            #expect(constructions == 1)
            if disableModule {
                try await scope.run("module enablement") {
                    try await container.services.moduleRuntime.setEnabled(false, for: owner)
                }
            } else {
                // Cancelling one UI request must leave the shared construction owned
                // by the runtime available to the second window.
                model.workbenchUIRegistry.perform(windows[0], model: model)
                release.open()
            }
            try await scope.run("window activation") { await firstTask?.value }
            try await scope.run("window activation") { await secondTask?.value }
            #expect(model.contributionActivationTasks.isEmpty)
            #expect(!model.workbenchFeature.isVisible(.init(rawValue: windows[0].id)))
            #expect(constructions == 1)
            if disableModule {
                let snapshot = try container.services.moduleRuntime.snapshot(for: owner)
                #expect(snapshot.state == .disabled && !snapshot.isInstantiated && snapshot.resources.isEmpty)
                #expect(container.services.moduleRuntime.contributions()[owner] == nil)
                #expect(!model.registeredContributions(at: .menu).contains { $0.actionID == first.actionID })
                staleAction?.perform()
                model.workbenchUIRegistry.performAction(id: first.actionID!, model: model)
                #expect(model.contributionActivationTasks.isEmpty)
                try await scope.run("module enablement") {
                    try await container.services.moduleRuntime.setEnabled(true, for: owner)
                }
                release.open()
                model.workbenchUIRegistry.perform(first, model: model)
                try await scope.run("window activation") { await model.contributionActivationTasks[windows[0].id]?.value }
                #expect(constructions == 2)
            } else {
                #expect(model.workbenchFeature.isVisible(.init(rawValue: windows[1].id)))
                #expect(commands.suffix(3).allSatisfy { model.workbenchUIRegistry.state(for: $0, model: model).isChecked })
                #expect(LitheActionRegistry.actions(for: model).first { $0.id == second.actionID }?.isChecked == true)
            }
        }
    }

    @Test func fileReadFailureStillShutsDownActivatedPluginSession() async throws {
        let declaration = try #require(descriptor().pluginManifest.modules.first)
        let suite = "lithe-ui-failed-session-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let started = TestGate(), release = TestGate()
        release.open()
        let module = GatedWorkbenchTestModule(declaration: declaration, started: started, release: release)
        try container.services.moduleRuntime.register(ModuleFactory(
            manifest: declaration.manifest, contributions: declaration.contributions) { module })
        let model = AppModel(settings: settings, services: container.services)
        var failedRead = false
        do {
            try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
                model.workspaceSessionCoordinator.beginWorkspace(at: URL(fileURLWithPath: "/fixture/failed-session"))
                try await scope.run("plugin activation before failed read") {
                    _ = try await container.services.moduleRuntime.activate(declaration.manifest.id)
                }
                #expect(module.isModuleResourceActive)
                _ = try Data(contentsOf: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lithe-missing-" + UUID().uuidString))
            }
        } catch let error as CocoaError {
            #expect(error.code == .fileReadNoSuchFile)
            failedRead = true
        }
        #expect(failedRead)
        #expect(!module.isModuleResourceActive)
        #expect(model.contributionActivationTasks.isEmpty)
        let snapshot = try container.services.moduleRuntime.snapshot(for: declaration.manifest.id)
        #expect(!snapshot.isInstantiated && snapshot.resources.isEmpty)
    }

    @Test func installedUIPluginActivatesThroughHostCommandsAndDisablesCleanly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-ui-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/hello-lithe.plugin.json"))
        try source.write(to: package.appendingPathComponent("plugin.json"))
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed"), validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(allowsLocalDevelopmentPackages: true)
        )
        let installed = try store.installPackage(from: package, origin: .localDevelopment)
        let startup = MacPluginStartupLoader.withHostUIValidation(packageStore: store).load(recoveryStore: nil)
        #expect(startup.issues.isEmpty)
        #expect(startup.registeredPlugins.count == 1)
        let declaration = try #require(installed.manifest.modules.first)
        let suite = "lithe-ui-activation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsStore = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: settingsStore)
        let container = MacServiceContainer(store: settingsStore, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let factories = MacServiceContainer.declarativePluginFactories(
            startup.registeredPlugins,
            executionHost: MacLanguageExecutionHost(processRegistry: ManagedProcessRegistry()),
            planner: DeclarativePluginTestSupport.operations
        )
        #expect(factories.count == 1)
        for factory in factories { try container.services.moduleRuntime.register(factory) }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            model.workspaceSessionCoordinator.beginWorkspace(at: root)
            _ = model.loadWorkbenchLayout(for: root)
            model.workbenchUIRegistry = try WorkbenchModuleUIComposition.registry(for: ValidatedPluginCatalog(
                manifests: BuiltInPluginCatalog.manifests + startup.registeredManifests,
                hostVersion: BuiltInPluginCatalog.hostVersion
            ))
            let command = try #require(model.registeredContributions(at: .toolbar).first { $0.id.hasPrefix(installed.manifest.id.rawValue) })
            let window = try #require(declaration.contributions.first { $0.kind == .toolWindow })
            #expect(container.services.moduleRuntime.snapshots().first { $0.manifest.id == declaration.manifest.id }?.isInstantiated == false)
            model.workbenchUIRegistry.perform(command, model: model)
            try await scope.run("window activation") { await model.contributionActivationTasks[window.id]?.value }
            #expect(model.workbenchFeature.activeRightToolWindow?.rawValue == window.id)
            #expect(model.registeredContributions(at: .menu).contains { $0.actionID == command.actionID })
            #expect(LitheActionRegistry.actions(for: model).contains { $0.id == command.actionID })
            model.workbenchFeature.customizeContribution(window.id, placement: .activityBar)
            #expect(model.workbenchFeature.activeToolWindow?.rawValue == window.id)
            model.workbenchFeature.customizeContribution(window.id, placement: .leftSidebar)
            #expect(model.workbenchFeature.activeToolWindow == nil)
            #expect(model.workbenchFeature.activeLeftToolWindow?.rawValue == window.id)
            #expect(model.leftSidebarContributions.contains { $0.id == window.id })
            try await scope.run("module enablement") {
                try await container.services.moduleRuntime.setEnabled(false, for: declaration.manifest.id)
            }
            #expect(model.workbenchFeature.activeLeftToolWindow == nil)
            #expect(!model.registeredContributions(at: .toolbar).contains { $0.actionID == command.actionID })
            model.workbenchUIRegistry.perform(command, model: model)
            #expect(model.contributionActivationTasks.isEmpty)
            try await scope.run("module enablement") {
                try await container.services.moduleRuntime.setEnabled(true, for: declaration.manifest.id)
            }
            #expect(model.workbenchFeature.contributionPreferences[window.id]?.placement == .leftSidebar)
            let layout = model.loadWorkbenchLayout(for: root)
            #expect(layout.isSidebarVisible == true)
            #expect(model.workbenchFeature.activeLeftToolWindow?.rawValue == window.id)
            #expect(container.services.moduleRuntime.snapshots().first { $0.manifest.id == declaration.manifest.id }?.isInstantiated == false)
            model.restoreRegisteredToolWindows([window.id])
            try await scope.run("window activation") { await model.contributionActivationTasks[window.id]?.value }
            #expect(container.services.moduleRuntime.snapshots().first { $0.manifest.id == declaration.manifest.id }?.isInstantiated == true)
            #expect(model.workbenchFeature.activeLeftToolWindow?.rawValue == window.id)
            #expect(try Data(contentsOf: installed.packageURL.appendingPathComponent("plugin.json")) == source)
        }
    }

    @Test func stableIDsMoveHideAndRestoreAcrossGeometryCommits() throws {
        let suite = "lithe-ui-host-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchLayoutStore(store: MacUserDefaultsStore(defaults: defaults))
        let workspace = URL(fileURLWithPath: "/fixture/workspace")
        let workbench = WorkbenchFeatureModel(layoutStore: store)
        let windows = BuiltInModuleCatalog.contributions(for: .database)
        workbench.reconcileContributions([.database: windows])
        _ = workbench.loadLayout(for: workspace)
        workbench.setVisibility(.database, isVisible: true)
        workbench.customizeContribution("database.workspace", placement: .activityBar)
        #expect(workbench.activeRightToolWindow == nil)
        #expect(workbench.activeToolWindow == .database)
        #expect(workbench.contributions(windows, at: .activityBar).contains { $0.id == "database.workspace" })
        store.save(WorkbenchLayout(sidebarWidth: 444, topPaneHeight: 555), for: workspace)
        let restored = WorkbenchFeatureModel(layoutStore: store)
        restored.reconcileContributions([.database: windows])
        let layout = restored.loadLayout(for: workspace)
        #expect(layout.sidebarWidth == 444)
        #expect(layout.visibleToolWindowIDs == ["database.workspace"])
        #expect(restored.contributionPreferences["database.workspace"]?.placement == .activityBar)
        restored.setVisibility(.database, isVisible: true)
        restored.customizeContribution("database.workspace", isHidden: true)
        #expect(!restored.isVisible(.database))
        #expect(restored.contributions(windows, at: .activityBar).map(\.id) == ["database.services"])
        restored.reconcileContributions([:])
        restored.reconcileContributions([.database: windows])
        #expect(restored.contributionPreferences["database.workspace"]?.isHidden == true)
        restored.customizeContribution("database.workspace", isHidden: false)
        #expect(restored.contributions(windows, at: .activityBar).count == 2)
    }

    @Test func equalOrdersReorderAndUnavailableOwnersReleaseTheirWindows() throws {
        let workbench = WorkbenchFeatureModel()
        let module = ModuleID("org.example.ui")
        let windows = ["org.example.a", "org.example.b"].map {
            ModuleContribution(id: $0, kind: .toolWindow, title: $0, order: 10)
        }
        workbench.reconcileContributions([module: windows])
        workbench.moveContribution(windows[1].id, earlier: true)
        #expect(workbench.contributions(windows, at: .activityBar).map(\.id) == windows.reversed().map(\.id))
        let window = WorkbenchFeatureModel.ToolWindow(rawValue: windows[0].id)
        workbench.setVisibility(window, isVisible: true)
        workbench.releaseContributions(for: module)
        #expect(!workbench.isVisible(window))
        workbench.setVisibility(window, isVisible: true)
        workbench.reconcileContributions([:])
        #expect(workbench.activeToolWindow == nil)
        workbench.customizeContribution(windows[0].id, placement: .menu)
        #expect(workbench.contributionPreferences[windows[0].id]?.placement == nil)
    }

    @Test func builtInCommandsUseTheHostRegistryWithoutRetainingTheModel() async throws {
        let suite = "lithe-ui-command-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        var model: AppModel? = AppModel(settings: settings, services: container.services)
        weak var released = model
        var settingsAction: LitheAction?
        try await WorkbenchTestScope.withCleanup({ await model?.shutdownProjectSession() }) { _ in
            let actions = LitheActionRegistry.actions(for: try #require(model))
            let action = try #require(actions.first { $0.id == "settings" })
            settingsAction = action
            #expect(Set(actions.map(\.id)) == Set(LitheCommandCatalog.commands.map(\.id)))
            #expect(actions.allSatisfy { $0.contributionID?.hasPrefix("workbench.command.") == true })
            #expect(action.group == .project && action.keyEquivalent != nil)
            let entry = try #require(model?.workbenchContributions.first { $0.id == action.contributionID })
            model?.workbenchFeature.customizeContribution(entry.id, isHidden: true)
            #expect(model.map { LitheActionRegistry.actions(for: $0).contains { $0.id == "settings" } } == false)
            model?.showContributionEntry(entry)
            #expect(model?.workbenchFeature.isSettingsPresented == false)
            #expect(model.map { LitheActionRegistry.actions(for: $0).contains { $0.id == "settings" } } == true)
            #expect(action.isEnabled)
            #expect(actions.first { $0.id == "save" }?.isEnabled == false)
            action.perform()
            #expect(model?.workbenchFeature.isSettingsPresented == true)
        }
        model = nil
        #expect(released == nil)
        // An action kept by an old menu is a weak binding and safely becomes inert.
        settingsAction?.perform()
    }

    @Test(arguments: [false, true])
    func hostRenderedTextWindowUsesSharedChrome(dark: Bool) async throws {
        let descriptor = try descriptor()
        let contribution = try #require(descriptor.pluginManifest.modules.first?.contributions.first { $0.kind == .toolWindow })
        let suite = "lithe-ui-render-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            let host = NSHostingView(rootView: DeclarativeToolWindowView(contribution: contribution, model: model)
                .environmentObject(model)
                .environmentObject(settings)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 480 && bitmap.pixelsHigh >= 300)
            let root = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent(".artifacts/ui-contributions")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent(dark ? "hello-dark.png" : "hello-light.png"))
        }
    }

    @Test(arguments: ["module", "application"])
    func conflictingPluginActionsAreIsolatedBeforeUIConstruction(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-ui-collision-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = kind == "module" ? "execution" : "workbench"
        let actionID = kind == "module" ? "execution.run.toggle" : "workbench.debug-start-or-restart"
        let windowID = id + ".info"
        let manifest: [String: Any] = [
            "schemaVersion": 2, "pluginAPIVersion": 2, "id": id, "displayName": "Collision fixture", "version": "1.0.0",
            "vendor": ["id": "example", "displayName": "Example", "signatureRequirement": "publisherPackage"],
            "permissions": ["ui.contribute"], "activationEvents": ["onView:" + windowID, "onCommand:" + actionID],
            "ui": ["toolWindows": [["id": windowID, "title": "Info", "placement": "right", "text": "Fixture"]],
                   "commands": [["id": actionID, "title": "Open info", "toolWindowID": windowID, "placements": ["toolbar"]]]]
        ]
        let package = try DeclarativePluginTestSupport.writePackage(at: root.appendingPathComponent("source"), manifest: manifest)
        let store = MacPluginPackageStore(rootURL: root.appendingPathComponent("installed"),
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(allowsLocalDevelopmentPackages: true))
        _ = try store.installPackage(from: package, origin: .localDevelopment)
        let startup = MacPluginStartupLoader.withHostUIValidation(packageStore: store).load(recoveryStore: nil)
        #expect(startup.installedPlugins.count == 1)
        #expect(startup.registeredPlugins.isEmpty)
        #expect(startup.issues.count == 1)
        #expect(startup.issues.first?.message.contains(actionID) == true)
        // The shell's catalog includes accepted packages only. Rejected
        // packages remain visible in management without registering actions.
        let accepted = try ValidatedPluginCatalog(manifests: BuiltInPluginCatalog.manifests + startup.registeredManifests,
            hostVersion: BuiltInPluginCatalog.hostVersion)
        let registry = try WorkbenchModuleUIComposition.registry(for: accepted)
        try registry.validate(contributions: BuiltInModuleCatalog.contributions(for: .execution))
    }

    @Test func sessionShutdownPreservesSavedWindowsAndUserHideStillPersists() async throws {
        let suite = "lithe-ui-shutdown-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layoutStore = WorkbenchLayoutStore(store: MacUserDefaultsStore(defaults: defaults))
        let workspace = URL(fileURLWithPath: "/fixture/workspace")
        let declaration = try #require(try descriptor().pluginManifest.modules.first)
        let runtime = ModuleRuntime()
        try runtime.register(ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
            DeclarativeWorkbenchModule(declaration: declaration)
        })
        let workbench = WorkbenchFeatureModel(layoutStore: layoutStore)
        workbench.reconcileContributions(runtime.availableContributions())
        let coordinator = ModuleSessionCoordinator(runtime: runtime, capabilities: ModuleCapabilityStore(), workbench: workbench,
            onModuleReleased: { _ in }, onChange: {})
        defer { coordinator.stopObserving() }
        let contribution = try #require(declaration.contributions.first { $0.kind == .toolWindow })
        let window = WorkbenchFeatureModel.ToolWindow(rawValue: contribution.id)
        _ = workbench.loadLayout(for: workspace)
        _ = try await runtime.activate(declaration.manifest.id)
        workbench.setVisibility(window, isVisible: true)
        workbench.customizeContribution(contribution.id, placement: .activityBar)
        await coordinator.shutdown()
        #expect(workbench.activeToolWindow == nil)
        #expect(layoutStore.load(for: workspace).visibleToolWindowIDs == [contribution.id])
        #expect(layoutStore.load(for: workspace).contributionPreferences?[contribution.id]?.placement == .activityBar)
        // A real user hide remains a durable edit after reopening the session.
        _ = workbench.loadLayout(for: workspace)
        workbench.setVisibility(window, isVisible: true)
        workbench.setVisibility(window, isVisible: false)
        await coordinator.shutdown()
        #expect(layoutStore.load(for: workspace).visibleToolWindowIDs == [])
    }

    @Test func disabledAgentSetupEntrySurvivesMovingAndModuleRelease() async throws {
        let suite = "lithe-ui-agent-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            model.workspaceSessionCoordinator.beginWorkspace(at: URL(fileURLWithPath: "/fixture/workspace"))
            #expect(!model.isAgentConversationEnabled)
            model.workbenchFeature.setVisibility(.agent, isVisible: true)
            model.workbenchFeature.customizeContribution("agent.conversation", placement: .activityBar)
            #expect(model.activityBarContributions.contains { $0.id == "agent.conversation" })
            #expect(!model.rightSidebarContributions.contains { $0.id == "agent.conversation" })
            #expect(model.workbenchUIRegistry.selectedToolContent(from: model.activityBarContributions, model: model).rendererID == "agent.conversation")
            container.services.moduleRuntime.publish(ModuleEvent(source: .agentConversation, name: "module.shutdown"))
            #expect(model.workbenchFeature.isVisible(.agent))
            model.workbenchFeature.customizeContribution("agent.conversation", isHidden: true)
            #expect(model.workbenchContributions.contains { $0.id == "agent.conversation" })
            model.workbenchFeature.customizeContribution("agent.conversation", isHidden: false)
            #expect(model.activityBarContributions.contains { $0.id == "agent.conversation" })
        }
    }

    @Test(arguments: [false, true])
    func savedServicesWindowActivatesItsOwnerWithoutAnotherEntry(useShow: Bool) async throws {
        let suite = "lithe-services-restore-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let workspace = URL(fileURLWithPath: "/fixture/services-restore")
        let firstContainer = MacServiceContainer(store: store, settings: settings)
        defer { firstContainer.moduleLifecycleCoordinator.stop() }
        let first = AppModel(settings: settings, services: firstContainer.services)
        try await WorkbenchTestScope.withCleanup({ await first.shutdownProjectSession() }) { scope in
            first.workspaceSessionCoordinator.beginWorkspace(at: workspace)
            _ = first.loadWorkbenchLayout(for: workspace)
            try await scope.run("initial Services activation") {
                await first.activateDatabaseModule(toolWindow: .databaseServices)
            }
            #expect(first.databaseFeatureIfActive != nil)
            #expect(first.workbenchFeature.isVisible(.databaseServices))
        }
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let restored = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await restored.shutdownProjectSession() }) { scope in
            restored.workspaceSessionCoordinator.beginWorkspace(at: workspace)
            let layout = restored.loadWorkbenchLayout(for: workspace)
            let services = try #require(restored.workbenchContributions.first { $0.id == "database.services" })
            #expect(restored.workbenchFeature.isVisible(.databaseServices))
            #expect(restored.databaseFeatureIfActive == nil)
            if useShow { restored.showContributionEntry(services) }
            else { restored.restoreRegisteredToolWindows(layout.toolWindows?.filter(\.isVisible).map(\.id) ?? []) }
            let activation = try #require(restored.contributionActivationTasks[services.id])
            try await scope.run("restored Services activation") { await activation.value }
            #expect(restored.databaseFeatureIfActive != nil)
            #expect(restored.workbenchFeature.isVisible(.databaseServices))
            #expect(!restored.workbenchFeature.isVisible(.database))
            #expect(restored.workbenchUIRegistry.isContentVisible(for: services, model: restored))
            #expect(try container.services.moduleRuntime.snapshot(for: .database).isInstantiated)
        }
    }

    @Test func rebuildJavaIndexIsEnabledOnlyWithAWorkspace() throws {
        let suite = "lithe-rebuild-index-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        #expect(!model.canPerformShortcutCommand(id: "rebuild-java-index"))
        model.workspaceSessionCoordinator.beginWorkspace(at: URL(fileURLWithPath: "/fixture/rebuild-index"))
        #expect(model.canPerformShortcutCommand(id: "rebuild-java-index"))
    }

    @Test func activationWaitsForGatedSleepWithoutReactivatingTheSleepingInstance() async throws {
        let runtime = ModuleRuntime()
        let owner = ModuleID("org.example.sleep-race")
        let contribution = ModuleContribution(id: owner.rawValue + ".window", kind: .toolWindow, title: "Sleep")
        let declaration = PluginModuleDeclaration(manifest: .init(id: owner, displayName: "Sleep", scope: .workspace),
            contributions: [contribution])
        let started = TestGate(), release = TestGate(), waiting = TestGate()
        let prepareStarted = TestGate(), prepareRelease = TestGate()
        release.open()
        var instances: [GatedWorkbenchTestModule] = []
        try runtime.register(ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
            let instance = GatedWorkbenchTestModule(declaration: declaration, started: started, release: release,
                prepareStarted: prepareStarted, prepareRelease: prepareRelease)
            instances.append(instance)
            return instance
        })
        var publications = 0
        let observer = runtime.observeEvents {
            if $0.name == "module.activation-waiting-for-transition" { waiting.open() }
            if $0.name == "module.activated" { publications += 1 }
        }
        defer { runtime.removeEventObserver(observer); prepareRelease.open() }
        try await WorkbenchTestScope.withCleanup({ await runtime.shutdownAll() }) { scope in
            defer { prepareRelease.open() }
            try await scope.run("initial activation") { _ = try await runtime.activate(owner) }
            let sleeping = Task { try await runtime.sleep(owner) }
            defer { sleeping.cancel() }
            #expect(await prepareStarted.waitUntilOpen(), "Sleep did not reach preparation")
            let activation = Task { _ = try await runtime.activate(owner) }
            defer { activation.cancel() }
            #expect(await waiting.waitUntilOpen(), "Activation did not wait for sleep")
            #expect(instances.count == 1 && instances[0].activationCount == 1)
            #expect(publications == 1)
            #expect(try runtime.snapshot(for: owner).state == .preparingToSleep)
            prepareRelease.open()
            try await scope.run("sleep completion") { try await sleeping.value }
            try await scope.run("wake completion") { try await activation.value }
            #expect(instances.count == 2)
            #expect(instances.allSatisfy { $0.activationCount == 1 })
            #expect(!instances[0].isModuleResourceActive && instances[1].isModuleResourceActive)
            #expect(publications == 2)
            #expect(runtime.contributions()[owner] == [contribution])
            #expect(try runtime.snapshot(for: owner).activity.activeResourceCount == 1)
        }
        #expect(instances.allSatisfy { !$0.isModuleResourceActive })
        #expect(runtime.contributions().isEmpty)
    }

    @Test func cancelledShutdownWaiterDoesNotRecreateModule() async throws {
        let runtime = ModuleRuntime()
        let owner = ModuleID("org.example.shutdown-race")
        let contribution = ModuleContribution(id: owner.rawValue + ".window", kind: .toolWindow, title: "Shutdown")
        let declaration = PluginModuleDeclaration(manifest: .init(id: owner, displayName: "Shutdown", scope: .workspace),
            contributions: [contribution])
        let started = TestGate(), release = TestGate(), waiting = TestGate()
        let shutdownStarted = TestGate(), shutdownRelease = TestGate()
        release.open()
        var instances: [GatedWorkbenchTestModule] = []
        try runtime.register(ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
            let instance = GatedWorkbenchTestModule(declaration: declaration, started: started, release: release,
                shutdownStarted: shutdownStarted, shutdownRelease: shutdownRelease)
            instances.append(instance)
            return instance
        })
        var publications = 0
        let observer = runtime.observeEvents {
            if $0.name == "module.activation-waiting-for-transition" { waiting.open() }
            if $0.name == "module.activated" { publications += 1 }
        }
        defer { runtime.removeEventObserver(observer); shutdownRelease.open() }
        try await WorkbenchTestScope.withCleanup({ await runtime.shutdownAll() }) { scope in
            defer { shutdownRelease.open() }
            try await scope.run("initial activation") { _ = try await runtime.activate(owner) }
            let shutdown = Task { try await runtime.shutdown(owner) }
            defer { shutdown.cancel() }
            #expect(await shutdownStarted.waitUntilOpen(), "Shutdown did not reach its gate")
            let waiter = Task {
                do { _ = try await runtime.activate(owner); return false }
                catch is CancellationError { return true }
                catch { Issue.record("Unexpected activation error: \(error)"); return false }
            }
            defer { waiter.cancel() }
            #expect(await waiting.waitUntilOpen(), "Activation did not wait for shutdown")
            waiter.cancel()
            shutdownRelease.open()
            try await scope.run("shutdown completion") { try await shutdown.value }
            try await scope.run("cancelled waiter completion") { #expect(await waiter.value) }
            #expect(instances.count == 1 && publications == 1)
            #expect(instances.allSatisfy { !$0.isModuleResourceActive })
            #expect(runtime.contributions().isEmpty)
            #expect(try !runtime.snapshot(for: owner).isInstantiated)
            #expect(try runtime.snapshot(for: owner).activity.activeResourceCount == 0)
        }
    }

    @Test func buildSystemWindowMovesRelativeToActualRailOrder() {
        let workbench = WorkbenchFeatureModel()
        let build = DeclarativeBuildSystem(id: "make", displayName: "Make", modelSource: nil, tasks: [], testScopes: [], dependencyScopes: [])
        workbench.reconcileContributions([
            .database: BuiltInModuleCatalog.contributions(for: .database),
            .agentConversation: BuiltInModuleCatalog.contributions(for: .agentConversation),
            .buildSystemsExtension("org.example.make"): build.contributions(pluginID: "org.example.make", order: 0)])
        let position = DockPosition(anchor: .right, group: .primary)
        let window = WorkbenchFeatureModel.ToolWindow(
            rawValue: DeclarativeBuildSystem.toolWindowID(pluginID: "org.example.make", buildSystemID: "make"))
        // A build system's window docks on the right like the Maven window it replaces.
        #expect(workbench.tools(in: position) == [.database, .agent, window])
        workbench.moveContribution(window.rawValue, earlier: true)
        #expect(workbench.tools(in: position) == [.database, window, .agent])
        workbench.moveContribution(window.rawValue, earlier: false)
        #expect(workbench.tools(in: position) == [.database, .agent, window])
    }

    @Test func servicesCommandActivatesDatabaseWithoutOpeningItsSidebar() async throws {
        let suite = "lithe-ui-services-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            model.workspaceSessionCoordinator.beginWorkspace(at: URL(fileURLWithPath: "/fixture/workspace"))
            #expect(model.databaseFeatureIfActive == nil)
            let services = try #require(model.workbenchContributions.first { $0.id == "database.services" })
            let opened = TestGate()
            let observation = model.workbenchFeature.$toolWindowStates.sink { states in
                if states.contains(where: { $0.id == WorkbenchFeatureModel.ToolWindow.databaseServices.rawValue && $0.isVisible }) { opened.open() }
            }
            defer { observation.cancel(); opened.open() }
            model.workbenchUIRegistry.perform(services, model: model)
            #expect(await opened.waitUntilOpen(), "Services never completed database activation")
            #expect(model.databaseFeatureIfActive != nil)
            #expect(model.workbenchFeature.isVisible(.databaseServices))
            #expect(!model.workbenchFeature.isVisible(.database))
            #expect(model.workbenchUIRegistry.selectedToolContent(from: model.activityBarContributions, model: model).rendererID == "database.services")
        }
    }

    @Test func duplicateIDsFailBeforeRenderingOrChangingTheRuntime() throws {
        let contribution = ModuleContribution(id: "duplicate", kind: .toolWindow, title: "Duplicate")
        #expect(throws: WorkbenchModuleUIRegistryError.duplicateContributionID("duplicate")) {
            try WorkbenchModuleUIRegistry(registrations: [.init(contributions: [contribution, contribution])])
        }
        let runtime = ModuleRuntime()
        let first = PluginModuleDeclaration(manifest: ModuleManifest(id: ModuleID("org.example.first"), displayName: "First", scope: .workspace), contributions: [contribution])
        try runtime.register(ModuleFactory(manifest: first.manifest, contributions: first.contributions) { DeclarativeWorkbenchModule(declaration: first) })
        #expect(throws: ModuleRuntimeError.duplicateContribution("duplicate")) {
            try runtime.register(ModuleFactory(manifest: ModuleManifest(id: ModuleID("org.example.second"), displayName: "Second", scope: .workspace), contributions: [contribution]) { DeclarativeWorkbenchModule(declaration: first) })
        }
        #expect(runtime.snapshots().count == 1)
        let descriptor = try descriptor()
        let manifests = [descriptor.pluginManifest, descriptor.pluginManifest]
        #expect(throws: PluginCatalogError.duplicatePlugin(descriptor.id)) {
            try ValidatedPluginCatalog(manifests: manifests, hostVersion: BuiltInPluginCatalog.hostVersion)
        }
    }
}

@MainActor
private final class GatedWorkbenchTestModule: LitheModule, ModuleResource {
    let declaration: PluginModuleDeclaration
    let started: TestGate
    let release: TestGate
    var manifest: ModuleManifest { declaration.manifest }
    let moduleResourceKind = "test-ui-activation"
    private(set) var isModuleResourceActive = false
    private(set) var activationCount = 0
    private let prepareStarted: TestGate?
    private let prepareRelease: TestGate?
    private let shutdownStarted: TestGate?
    private let shutdownRelease: TestGate?
    init(declaration: PluginModuleDeclaration, started: TestGate, release: TestGate,
         prepareStarted: TestGate? = nil, prepareRelease: TestGate? = nil,
         shutdownStarted: TestGate? = nil, shutdownRelease: TestGate? = nil) {
        self.declaration = declaration
        self.started = started
        self.release = release
        self.prepareStarted = prepareStarted
        self.prepareRelease = prepareRelease
        self.shutdownStarted = shutdownStarted
        self.shutdownRelease = shutdownRelease
    }
    func activate(context: ModuleContext) async throws {
        activationCount += 1
        isModuleResourceActive = true
        context.resources.register(self)
        started.open()
        let opened = await release.waitUntilOpen()
        #expect(opened || Task.isCancelled, "Test did not release UI module activation")
    }
    func contributions() -> [ModuleContribution] { declaration.contributions }
    func prepareForSleep() async throws {
        prepareStarted?.open()
        if let prepareRelease { #expect(await prepareRelease.waitUntilOpen(), "Sleep gate was not released") }
    }
    func sleep() async { isModuleResourceActive = false }
    func shutdown() async {
        shutdownStarted?.open()
        if let shutdownRelease { #expect(await shutdownRelease.waitUntilOpen(), "Shutdown gate was not released") }
        isModuleResourceActive = false
    }
    func stopModuleResource() async { isModuleResourceActive = false }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
