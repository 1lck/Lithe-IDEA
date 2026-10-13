import SwiftUI
import Testing
@testable import Lithe
import LitheModuleAPI

@MainActor
struct WorkbenchModuleUIRegistryTests {
    @Test func mavenNavigationIsDockedAndBuildOutputStaysInTheActivityBar() throws {
        let contributions = BuiltInModuleCatalog.contributions(for: .execution)
        let navigation = try #require(contributions.first { $0.id == "execution.maven" })
        let output = try #require(contributions.first { $0.id == "execution.maven.output" })
        let registry = WorkbenchModuleUIComposition.builtIn

        #expect(navigation.placement == .rightSidebar)
        #expect(output.placement == .activityBar)
        #expect(navigation.actionID != output.actionID)
        #expect(registry.renderer(for: navigation)?.rightSidebarBehavior == .docked)
        #expect(registry.renderer(for: navigation)?.ideaAssetPath == "maven/toolWindowMaven.svg")
        #expect(registry.renderer(for: output) != nil)
        try registry.validate(contributions: contributions)
    }

    @Test func agentConversationIsDockedInTheRightSidebar() throws {
        let contributions = BuiltInModuleCatalog.contributions(for: .agentConversation)
        let agent = try #require(contributions.first { $0.id == "agent.conversation" })
        let registry = WorkbenchModuleUIComposition.builtIn

        #expect(agent.placement == .rightSidebar)
        #expect(registry.renderer(for: agent)?.rightSidebarBehavior == .docked)
        try registry.validate(contributions: contributions)
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
