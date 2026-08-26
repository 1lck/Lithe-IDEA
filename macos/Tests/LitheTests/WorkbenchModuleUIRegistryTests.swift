import SwiftUI
import Testing
@testable import Lithe
import LitheModuleAPI

@MainActor
struct WorkbenchModuleUIRegistryTests {
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
