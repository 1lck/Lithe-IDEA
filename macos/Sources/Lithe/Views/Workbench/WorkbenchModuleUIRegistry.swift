import Foundation
import LitheModuleAPI
import SwiftUI

enum WorkbenchModuleUIRegistryError: Error, Equatable, LocalizedError {
    case duplicateContributionID(String)
    case duplicateActionID(String)
    case duplicateRendererID(String)
    case missingAction(contributionID: String, actionID: String)
    case missingRenderer(contributionID: String, rendererID: String)
    var errorDescription: String? {
        switch self {
        case .duplicateContributionID(let id): "UI contribution \(id) is declared more than once."
        case .duplicateActionID(let id): "UI action \(id) is registered more than once."
        case .duplicateRendererID(let id): "UI renderer \(id) is registered more than once."
        case .missingAction(let contribution, let action): "UI contribution \(contribution) references missing action \(action)."
        case .missingRenderer(let contribution, let renderer): "UI contribution \(contribution) references missing renderer \(renderer)."
        }
    }

}

/// Host-side adapters for module-declared action and renderer identifiers.
/// This type owns only registration and lookup. Concrete built-in adapters are
/// assembled by the application composition root.
@MainActor
struct WorkbenchModuleUIRegistry {
    struct ActionState: Equatable {
        var isVisible = true
        var isEnabled = true
        var isChecked = false
        var isPending = false
        static let unavailable = Self(isVisible: false, isEnabled: false)
    }

    struct Action {
        let id: String
        let perform: @MainActor (AppModel) -> Void
        /// Native activation also binds feature observations; restoration must not toggle content.
        let activateOwner: (@MainActor (AppModel) async -> Bool)?
        let state: @MainActor (AppModel) -> ActionState
        init(id: String, perform: @escaping @MainActor (AppModel) -> Void,
             activateOwner: (@MainActor (AppModel) async -> Bool)? = nil,
             state: @escaping @MainActor (AppModel) -> ActionState = { _ in .init() }) {
            self.id = id
            self.perform = perform
            self.activateOwner = activateOwner
            self.state = state
        }
    }

    struct Renderer {
        enum RightSidebarBehavior {
            case hover
            case docked
        }
        let id: String
        let ideaAssetPath: String?
        let isVisible: @MainActor (AppModel) -> Bool
        let isEnabled: @MainActor (AppModel) -> Bool
        let help: String?
        let isSelected: @MainActor (AppModel) -> Bool
        let content: @MainActor (AppModel) -> AnyView
        /// Distinguishes states the erased content cannot express by value —
        /// chiefly "still loading" versus a specific attached feature object.
        let contentIdentity: @MainActor (AppModel) -> AnyHashable
        let rightSidebarBehavior: RightSidebarBehavior
        /// Set by tool windows whose content can also live as an editor tab.
        /// Dropping the stripe button onto the editor area invokes it.
        let openInEditor: (@MainActor (AppModel) -> Void)?

        init(
            id: String,
            ideaAssetPath: String?,
            isVisible: @escaping @MainActor (AppModel) -> Bool,
            isSelected: @escaping @MainActor (AppModel) -> Bool,
            content: @escaping @MainActor (AppModel) -> AnyView,
            // Renderers whose content depends on nothing but the hosted view's
            // own observation of AppModel are always interchangeable.
            contentIdentity: @escaping @MainActor (AppModel) -> AnyHashable = { _ in 0 },
            rightSidebarBehavior: RightSidebarBehavior = .hover,
            isEnabled: @escaping @MainActor (AppModel) -> Bool = { _ in true },
            help: String? = nil,
            openInEditor: (@MainActor (AppModel) -> Void)? = nil
        ) {
            self.id = id
            self.ideaAssetPath = ideaAssetPath
            self.isVisible = isVisible
            self.isEnabled = isEnabled
            self.help = help
            self.isSelected = isSelected
            self.content = content
            self.contentIdentity = contentIdentity
            self.rightSidebarBehavior = rightSidebarBehavior
            self.openInEditor = openInEditor
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

    private let actions: [String: Action]
    private let renderers: [String: Renderer]
    private var iconAssets: [String: WorkbenchContributionIcon.Asset] = [:]

    init(registrations: [Registration]) throws {
        var actions: [String: Action] = [:]
        var renderers: [String: Renderer] = [:]

        var contributionIDs: Set<String> = []
        for registration in registrations {
            for contribution in registration.contributions {
                guard contributionIDs.insert(contribution.id).inserted else {
                    throw WorkbenchModuleUIRegistryError.duplicateContributionID(contribution.id)
                }
            }
            for action in registration.actions {
                guard actions[action.id] == nil else {
                    throw WorkbenchModuleUIRegistryError.duplicateActionID(action.id)
                }
                actions[action.id] = action
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
        registerIcons(registrations.flatMap(\.contributions).filter { $0.uiIcon != nil }, resources: [:])
    }

    /// Every data-only plugin uses this adapter; no plugin ID switches or
    /// plugin-specific workbench branches are allowed here.
    static func declarativeRegistration(_ declaration: PluginModuleDeclaration, iconResources: [String: PluginUIIconResources] = [:]) -> Registration {
        var actions: [Action] = []
        var actionIDs: Set<String> = []
        var renderers: [Renderer] = []
        for contribution in declaration.contributions {
            if let actionID = contribution.actionID, actionIDs.insert(actionID).inserted {
                actions.append(Action(id: actionID, perform: { model in
                    model.performToolWindowContribution(contribution, owner: declaration.manifest.id)
                }, state: { model in
                    let target = contribution.kind == .toolWindow ? contribution.id : contribution.visibility["toolWindowID"]
                    let pending = target.map { model.contributionActivationTasks[$0] != nil } ?? false
                    return ActionState(isVisible: model.workspaceURL != nil,
                        isEnabled: model.workspaceURL != nil && (contribution.kind == .toolWindow || !pending),
                        isChecked: target.map { model.workbenchFeature.isVisible(.init(rawValue: $0)) } ?? false,
                        isPending: pending)
                }))
            }
            if contribution.kind == .toolWindow, let rendererID = contribution.rendererID {
                let window = WorkbenchFeatureModel.ToolWindow(rawValue: contribution.id)
                let icon = WorkbenchContributionIcon.Asset(contribution.uiIcon, resources: iconResources[contribution.id])
                renderers.append(Renderer(
                    id: rendererID, ideaAssetPath: "expui/toolwindows/toolWindowComponents@20x20.svg",
                    isVisible: { $0.workspaceURL != nil },
                    isSelected: { $0.workbenchFeature.isVisible(window) },
                    content: { model in AnyView(DeclarativeToolWindowView(contribution: contribution, model: model,
                        icon: WorkbenchContributionIcon(asset: icon, role: .header))) },
                    rightSidebarBehavior: .docked
                ))
            }
        }
        return Registration(contributions: declaration.contributions, actions: actions, renderers: renderers)
    }

    mutating func registerIcons(_ contributions: [ModuleContribution], resources: [String: PluginUIIconResources]) {
        for contribution in contributions where contribution.uiIcon != nil || contribution.kind == .toolWindow {
            iconAssets[contribution.id] = .init(contribution.uiIcon, resources: resources[contribution.id])
        }
    }

    func icon(for contribution: ModuleContribution, role: WorkbenchContributionIcon.Role) -> AnyView? {
        iconAssets[contribution.id].map { AnyView(WorkbenchContributionIcon(asset: $0, role: role)) }
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

    func ownerActivation(for contribution: ModuleContribution) -> (@MainActor (AppModel) async -> Bool)? {
        contribution.actionID.flatMap { actions[$0]?.activateOwner }
    }

    func isContentVisible(for contribution: ModuleContribution, model: AppModel) -> Bool {
        let state = state(for: contribution, model: model)
        guard state.isVisible && state.isEnabled, let renderer = renderer(for: contribution) else { return false }
        return renderer.isVisible(model) && renderer.isSelected(model)
    }

    /// `available` lets list builders pass one snapshot of the workbench
    /// contributions instead of rebuilding it for every entry they evaluate.
    func state(for contribution: ModuleContribution, model: AppModel,
               available: [ModuleContribution]? = nil) -> ActionState {
        guard (available ?? model.workbenchContributions).contains(contribution),
              let id = contribution.actionID, let action = actions[id] else { return .unavailable }
        var state = action.state(model)
        if let renderer = renderer(for: contribution) {
            // Renderer visibility governs discovery in the rail, not whether
            // Show can activate an inactive module (for example Services).
            state.isEnabled = state.isEnabled && renderer.isEnabled(model)
            state.isChecked = renderer.isSelected(model)
        }
        return state
    }

    func state(forActionID id: String, model: AppModel) -> ActionState {
        if let contribution = model.workbenchContributions.first(where: { $0.actionID == id }) {
            return state(for: contribution, model: model)
        }
        guard LitheCommandCatalog.command(id: id) != nil,
              let action = actions[id] else { return .unavailable }
        return action.state(model)
    }

    func performAction(id: String, model: AppModel) {
        let state = state(forActionID: id, model: model)
        guard state.isVisible && state.isEnabled else { return }
        actions[id]?.perform(model)
    }

    func perform(_ contribution: ModuleContribution, model: AppModel) {
        let state = state(for: contribution, model: model)
        guard state.isVisible && state.isEnabled, let actionID = contribution.actionID else { return }
        actions[actionID]?.perform(model)
    }

    func selectedToolContent(
        from contributions: [ModuleContribution],
        model: AppModel
    ) -> ModuleToolContent {
        for contribution in contributions {
            guard let renderer = renderer(for: contribution), renderer.isVisible(model), renderer.isSelected(model) else { continue }
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
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.editor)
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
