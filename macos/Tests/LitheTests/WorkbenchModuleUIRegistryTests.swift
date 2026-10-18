import Foundation
import SwiftUI
import Testing
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI

@MainActor
struct WorkbenchModuleUIRegistryTests {
    @Test func actionInvocationRechecksPolicyAndRejectsChangedContributionMetadata() async throws {
        let suite = "lithe-action-policy-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            let project = try #require(model.workbenchContributions.first { $0.id == "workspace.project" })
            var allowed = true, visible = true, invocations = 0
            let registry = try WorkbenchModuleUIRegistry(registrations: [.init(actions: [
                .init(id: project.actionID!, perform: { _ in invocations += 1 },
                      state: { _ in .init(isVisible: visible, isEnabled: allowed) })
            ])])
            #expect(registry.state(for: project, model: model).isEnabled)
            allowed = false
            registry.performAction(id: project.actionID!, model: model)
            registry.perform(project, model: model)
            #expect(invocations == 0)
            allowed = true
            visible = false
            registry.perform(project, model: model)
            #expect(invocations == 0)
            visible = true
            let stale = ModuleContribution(id: project.id, kind: project.kind, title: "Changed metadata", actionID: project.actionID)
            registry.perform(stale, model: model)
            #expect(invocations == 0)
            registry.perform(project, model: model)
            #expect(invocations == 1)
        }
    }

    @Test func nativeSidebarEntriesHaveCompleteHostBindings() throws {
        let catalog = [.workspace, .git, .search].flatMap { BuiltInModuleCatalog.contributions(for: $0) }
        let registry = WorkbenchModuleUIComposition.builtIn
        let sidebars = catalog.filter { $0.placement == .leftSidebar }
        #expect(Set(sidebars.map(\.id)) == ["workspace.project", "git.changes", "search.workspace", "github.pull-requests"])
        #expect(sidebars.allSatisfy { $0.actionID != nil && $0.rendererID == $0.id })
        #expect(sidebars.allSatisfy { registry.renderer(for: $0)?.rightSidebarBehavior == .docked })
        try registry.validate(contributions: catalog)
    }

    @Test func nativeSidebarActionsFollowHostPlacementAndModuleAvailability() async throws {
        let suite = "lithe-sidebar-registry-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            let search = try #require(model.workbenchContributions.first { $0.id == "search.workspace" })
            let project = try #require(model.workbenchContributions.first { $0.id == "workspace.project" })
            let renderer = try #require(model.workbenchUIRegistry.renderer(for: project))
            let identity = renderer.contentIdentity(model)
            settings.projectTreeRowHeight += 1
            #expect(renderer.contentIdentity(model) != identity)
            model.workbenchFeature.customizeContribution(search.id, placement: .rightSidebar)
            model.workbenchUIRegistry.perform(search, model: model)
            #expect(model.workbenchFeature.isVisible(.search))
            #expect(model.workbenchFeature.activeRightToolWindow == .search)
            #expect(model.workbenchFeature.activeLeftToolWindow == .project)
            let content = model.workbenchUIRegistry.selectedToolContent(from: model.rightSidebarContributions, model: model)
            #expect(content.rendererID == search.rendererID)
            try await scope.run("module enablement") {
                try await container.services.moduleRuntime.setEnabled(false, for: .search)
            }
            #expect(model.workbenchFeature.activeRightToolWindow == nil)
            model.workbenchUIRegistry.perform(search, model: model)
            #expect(model.workbenchFeature.activeRightToolWindow == nil)
            #expect(!model.leftSidebarContributions.contains { $0.id == search.id })
            let pullRequests = try #require(model.workbenchContributions.first { $0.id == "github.pull-requests" })
            #expect(model.workbenchUIRegistry.renderer(for: pullRequests)?.isEnabled(model) == false)
            model.workbenchUIRegistry.perform(pullRequests, model: model)
            #expect(!model.workbenchFeature.isVisible(.pullRequests))
        }
    }

    @Test func buildSystemWindowIsDockedAndBuildOutputStaysInTheActivityBar() throws {
        let build = DeclarativeBuildSystem(id: "make", displayName: "Make", modelSource: nil, tasks: [], testScopes: [], dependencyScopes: [])
        let owner = ModuleID.buildSystemsExtension("org.example.make")
        let declaration = PluginModuleDeclaration(
            manifest: .init(id: owner, displayName: "Make", scope: .workspace),
            contributions: build.contributions(pluginID: "org.example.make", order: 0)
        )
        let registration = WorkbenchModuleUIRegistry.buildSystemRegistration(declaration)
        let registry = try WorkbenchModuleUIRegistry(registrations: [registration])
        let window = try #require(declaration.contributions.first { $0.kind == .toolWindow })
        let command = try #require(declaration.contributions.first { $0.kind == .command })
        let output = try #require(BuiltInModuleCatalog.contributions(for: .execution).first { $0.id == "execution.build.output" })

        #expect(window.placement == .rightSidebar)
        #expect(window.title == "Make")
        #expect(command.placement == .commandPalette)
        #expect(command.actionID != window.actionID)
        #expect(output.placement == .activityBar)
        #expect(registry.renderer(for: window)?.rightSidebarBehavior == .docked)
        try registry.validate(contributions: declaration.contributions)
        try WorkbenchModuleUIComposition.builtIn.validate(contributions: [output])
    }

    @Test func agentConversationIsDockedInTheRightSidebar() throws {
        let contributions = BuiltInModuleCatalog.contributions(for: .agentConversation)
        let agent = try #require(contributions.first { $0.id == "agent.conversation" })
        let registry = WorkbenchModuleUIComposition.builtIn

        #expect(agent.placement == .rightSidebar)
        #expect(registry.renderer(for: agent)?.rightSidebarBehavior == .docked)
        try registry.validate(contributions: contributions)
    }

    @Test func databaseUsesTheRightDockWithoutReplacingTheProjectTreeOrTerminal() throws {
        let contributions = BuiltInModuleCatalog.contributions(for: .database)
        let database = try #require(contributions.first { $0.id == "database.workspace" })
        let registry = WorkbenchModuleUIComposition.builtIn
        #expect(database.placement == .rightSidebar)
        #expect(registry.renderer(for: database)?.rightSidebarBehavior == .docked)
        try registry.validate(contributions: contributions)

        let workbench = WorkbenchFeatureModel()
        workbench.setVisibility(.terminal, isVisible: true)
        workbench.setVisibility(.database, isVisible: true)
        #expect(workbench.selectedSidebar == .project)
        #expect(workbench.isSidebarVisible)
        #expect(workbench.activeToolWindow == .terminal)
        #expect(workbench.activeRightToolWindow == .database)
        workbench.setVisibility(.agent, isVisible: true)
        #expect(!workbench.isVisible(.database))
        #expect(workbench.isVisible(.terminal))
    }

    @Test func duplicateActionIDsAreRejected() {
        let first = WorkbenchModuleUIRegistry.Registration(actions: [
            .init(id: "test.action", perform: { _ in })
        ])
        let second = WorkbenchModuleUIRegistry.Registration(actions: [
            .init(id: "test.action", perform: { _ in })
        ])

        #expect(throws: WorkbenchModuleUIRegistryError.duplicateActionID("test.action")) {
            try WorkbenchModuleUIRegistry(registrations: [first, second])
        }
    }

    @Test func duplicateRendererIDsAreRejected() {
        let renderer = WorkbenchModuleUIRegistry.Renderer(
            id: "test.renderer",
            ideaAssetPath: nil,
            isVisible: { _ in true },
            isSelected: { _ in false },
            content: { _ in AnyView(EmptyView()) }
        )

        #expect(throws: WorkbenchModuleUIRegistryError.duplicateRendererID("test.renderer")) {
            try WorkbenchModuleUIRegistry(registrations: [
                .init(renderers: [renderer]),
                .init(renderers: [renderer])
            ])
        }
    }

    @Test func missingActionAndRendererBindingsAreRejected() throws {
        let registry = try WorkbenchModuleUIRegistry(registrations: [])

        #expect(throws: WorkbenchModuleUIRegistryError.missingAction(
            contributionID: "test.tool",
            actionID: "test.action"
        )) {
            try registry.validate(contributions: [
                ModuleContribution(
                    id: "test.tool",
                    kind: .toolWindow,
                    title: "Test",
                    actionID: "test.action"
                )
            ])
        }

        #expect(throws: WorkbenchModuleUIRegistryError.missingRenderer(
            contributionID: "test.tool",
            rendererID: "test.renderer"
        )) {
            try registry.validate(contributions: [
                ModuleContribution(
                    id: "test.tool",
                    kind: .toolWindow,
                    title: "Test",
                    rendererID: "test.renderer"
                )
            ])
        }
    }

    @Test func composedBindingsValidateDeclaredContribution() throws {
        let registry = try WorkbenchModuleUIRegistry(registrations: [
            .init(
                actions: [.init(id: "test.action", perform: { _ in })],
                renderers: [
                    .init(
                        id: "test.renderer",
                        ideaAssetPath: nil,
                        isVisible: { _ in true },
                        isSelected: { _ in false },
                        content: { _ in AnyView(EmptyView()) }
                    )
                ]
            )
        ])

        try registry.validate(contributions: [
            ModuleContribution(
                id: "test.tool",
                kind: .toolWindow,
                title: "Test",
                actionID: "test.action",
                rendererID: "test.renderer"
            )
        ])
    }
}
