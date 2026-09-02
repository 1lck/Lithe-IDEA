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
        /// Distinguishes states the erased content cannot express by value —
        /// chiefly "still loading" versus a specific attached feature object.
        let contentIdentity: @MainActor (AppModel) -> AnyHashable

        init(
            id: String,
            ideaAssetPath: String?,
            isVisible: @escaping @MainActor (AppModel) -> Bool,
            isSelected: @escaping @MainActor (AppModel) -> Bool,
            content: @escaping @MainActor (AppModel) -> AnyView,
            // Renderers whose content depends on nothing but the hosted view's
            // own observation of AppModel are always interchangeable.
            contentIdentity: @escaping @MainActor (AppModel) -> AnyHashable = { _ in 0 }
        ) {
            self.id = id
            self.ideaAssetPath = ideaAssetPath
            self.isVisible = isVisible
            self.isSelected = isSelected
            self.content = content
            self.contentIdentity = contentIdentity
        }

        /// Identity for renderers built from an optional feature object. The
        /// loading placeholder and each distinct feature instance must compare
        /// differently, or switching workspaces would keep showing the previous
        /// workspace's feature.
        static func featureIdentity(_ feature: AnyObject?) -> AnyHashable {
            guard let feature else { return AnyHashable(Self.loadingIdentity) }
            return AnyHashable(ObjectIdentifier(feature))
        }

        private static let loadingIdentity = "module-loading"
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
    ) -> ModuleToolContent {
        for contribution in contributions {
            guard let renderer = renderer(for: contribution), renderer.isSelected(model) else { continue }
            return ModuleToolContent(
                rendererID: renderer.id,
                contentIdentity: renderer.contentIdentity(model),
                content: renderer.content(model)
            )
        }
        return ModuleToolContent(
            rendererID: Self.loadingRendererID,
            contentIdentity: 0,
            content: AnyView(Self.moduleLoadingView)
        )
    }

    private static let loadingRendererID = "workbench.module-loading"

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

/// Restores a comparable identity to a tool window that the registry had to
/// erase to `AnyView`.
///
/// `AnyView` defeats SwiftUI's value comparison, so every `WorkbenchView.body`
/// pass — including one per frame while a divider is dragged — forced the whole
/// bottom tool window to re-evaluate. The hosted views observe `AppModel`
/// themselves and stay live when this one is skipped, so comparing which
/// renderer is showing (and which feature it was built from) is sufficient.
/// This mirrors `GitGraphRowView`, whose `==` deliberately ignores its actions.
struct ModuleToolContent: View, Equatable {
    let rendererID: String
    let contentIdentity: AnyHashable
    let content: AnyView

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rendererID == rhs.rendererID && lhs.contentIdentity == rhs.contentIdentity
    }

    var body: some View { content }
}
