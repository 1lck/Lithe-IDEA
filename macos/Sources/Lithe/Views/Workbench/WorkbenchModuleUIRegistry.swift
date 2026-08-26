import Foundation
import LitheModuleAPI
import SwiftUI

enum WorkbenchModuleUIRegistryError: Error, Equatable {
    case duplicateActionID(String)
    case duplicateRendererID(String)
    case missingAction(contributionID: String, actionID: String)
    case missingRenderer(contributionID: String, rendererID: String)
}

/// Host-side adapters for module-declared action and renderer identifiers.
/// This type owns only registration and lookup. Concrete built-in adapters are
/// assembled by the application composition root.
@MainActor
struct WorkbenchModuleUIRegistry {
    struct Action {
        let id: String
        let perform: @MainActor (AppModel) -> Void
    }

    struct Renderer {
        let id: String
        let ideaAssetPath: String?
        let isVisible: @MainActor (AppModel) -> Bool
        let isSelected: @MainActor (AppModel) -> Bool
        let content: @MainActor (AppModel) -> AnyView
    }

    struct Registration {
        let contributions: [ModuleContribution]
        let actions: [Action]
        let renderers: [Renderer]

        init(
            contributions: [ModuleContribution] = [],
            actions: [Action] = [],
            renderers: [Renderer] = []
        ) {
            self.contributions = contributions
            self.actions = actions
            self.renderers = renderers
        }
    }

    private let actions: [String: @MainActor (AppModel) -> Void]
    private let renderers: [String: Renderer]

    init(registrations: [Registration]) throws {
        var actions: [String: @MainActor (AppModel) -> Void] = [:]
        var renderers: [String: Renderer] = [:]

        for registration in registrations {
            for action in registration.actions {
                guard actions[action.id] == nil else {
                    throw WorkbenchModuleUIRegistryError.duplicateActionID(action.id)
                }
                actions[action.id] = action.perform
            }
            for renderer in registration.renderers {
                guard renderers[renderer.id] == nil else {
                    throw WorkbenchModuleUIRegistryError.duplicateRendererID(renderer.id)
                }
                renderers[renderer.id] = renderer
            }
        }

        self.actions = actions
        self.renderers = renderers
        try validate(contributions: registrations.flatMap(\.contributions))
    }

    func validate(contributions: [ModuleContribution]) throws {
        for contribution in contributions {
            if let actionID = contribution.actionID, actions[actionID] == nil {
                throw WorkbenchModuleUIRegistryError.missingAction(
                    contributionID: contribution.id,
                    actionID: actionID
                )
            }
            if let rendererID = contribution.rendererID, renderers[rendererID] == nil {
                throw WorkbenchModuleUIRegistryError.missingRenderer(
                    contributionID: contribution.id,
                    rendererID: rendererID
                )
            }
        }
    }

    func renderer(for contribution: ModuleContribution) -> Renderer? {
        guard let rendererID = contribution.rendererID else { return nil }
        return renderers[rendererID]
    }

    func perform(_ contribution: ModuleContribution, model: AppModel) {
        guard let actionID = contribution.actionID else { return }
        actions[actionID]?(model)
    }

    func selectedToolContent(
        from contributions: [ModuleContribution],
        model: AppModel
    ) -> AnyView {
        for contribution in contributions {
            guard let renderer = renderer(for: contribution), renderer.isSelected(model) else { continue }
            return renderer.content(model)
        }
        return AnyView(Self.moduleLoadingView)
    }

    static var moduleLoadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Starting module...")
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LitheTheme.editor)
    }
}
