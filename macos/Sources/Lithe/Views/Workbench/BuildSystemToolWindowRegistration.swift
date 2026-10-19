import LitheCoreContracts
import LitheModuleAPI
import SwiftUI

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

extension WorkbenchModuleUIRegistry {
    /// The tool windows of one plugin's build systems. Every window uses the
    /// same view; the contribution's visibility keys say which build system
    /// it lists, so no plugin or build-system name appears here.
    static func buildSystemRegistration(
        _ declaration: PluginModuleDeclaration,
        iconResources: [String: PluginUIIconResources] = [:]
    ) -> Registration {
        let owner = declaration.manifest.id
        var actions: [Action] = []
        var renderers: [Renderer] = []
        for window in declaration.contributions where window.kind == .toolWindow {
            guard let actionID = window.actionID, let rendererID = window.rendererID,
                  let pluginID = window.visibility[DeclarativeBuildSystem.pluginIDKey],
                  let buildSystemID = window.visibility[DeclarativeBuildSystem.buildSystemIDKey] else { continue }
            let tool = WorkbenchFeatureModel.ToolWindow(rawValue: window.id)
            let icons = BuildSystemToolWindowIcons(
                windowID: window.id,
                window: WorkbenchContributionIcon.Asset(window.uiIcon, resources: iconResources[window.id]),
                resources: iconResources
            )
            // Detection runs in the execution module when the window opens.
            let activate: @MainActor (AppModel) async -> Bool = { model in
                do {
                    _ = try await model.services.moduleRuntime.activate(owner)
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) { model.showNotification(error.localizedDescription) }
                    return false
                }
                guard !Task.isCancelled, let access = await model.activateExecutionModule() else { return false }
                model.loadBuildSystems(access)
                return true
            }
            let toggle: @MainActor (AppModel) -> Void = { $0.performToolWindowContribution(window, owner: owner) }
            actions.append(Action(id: actionID, perform: toggle, activateOwner: activate, state: { model in
                ActionState(
                    isVisible: model.workspaceURL != nil, isEnabled: model.workspaceURL != nil,
                    isChecked: model.workbenchFeature.isVisible(tool),
                    isPending: model.contributionActivationTasks[window.id] != nil
                )
            }))
            // The palette command toggles the same window. Both are offered
            // in every open workspace while the plugin is enabled; the window
            // explains when no instance of the build system was detected.
            for command in declaration.contributions where command.kind == .command
                && command.visibility["toolWindowID"] == window.id {
                guard let commandActionID = command.actionID, commandActionID != actionID else { continue }
                actions.append(Action(id: commandActionID, perform: toggle, state: { model in
                    let available = model.workspaceURL != nil
                    let pending = model.contributionActivationTasks[window.id] != nil
                    return ActionState(
                        isVisible: available, isEnabled: available && !pending,
                        isChecked: model.workbenchFeature.isVisible(tool), isPending: pending
                    )
                }))
            }
            renderers.append(Renderer(
                id: rendererID, ideaAssetPath: "expui/toolwindows/toolWindowComponents@20x20.svg",
                isVisible: { $0.workspaceURL != nil },
                isSelected: { $0.workbenchFeature.isVisible(tool) },
                content: { model in
                    guard let feature = model.buildSystemsFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView.task { _ = await activate(model) })
                    }
                    return AnyView(BuildSystemToolWindowView(
                        feature: feature, title: window.title, toolWindow: tool,
                        pluginID: pluginID, buildSystemID: buildSystemID, icons: icons
                    ))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.buildSystemsFeatureIfActive) },
                rightSidebarBehavior: .docked
            ))
        }
        return Registration(contributions: declaration.contributions, actions: actions, renderers: renderers)
    }
}

/// Icons of one build-system window. Option icons are decoded once, on
/// first use, instead of on every render while a build streams output.
@MainActor
final class BuildSystemToolWindowIcons {
    let window: WorkbenchContributionIcon.Asset
    private let windowID: String
    private let resources: [String: PluginUIIconResources]
    private var options: [String: WorkbenchContributionIcon.Asset] = [:]

    init(windowID: String, window: WorkbenchContributionIcon.Asset, resources: [String: PluginUIIconResources]) {
        self.windowID = windowID
        self.window = window
        self.resources = resources
    }

    /// Nil when the option declares no icon; the view then uses its own.
    func option(_ option: DeclarativeBuildSystem.Option) -> WorkbenchContributionIcon.Asset? {
        guard let icon = option.icon else { return nil }
        if let asset = options[option.id] { return asset }
        let key = DeclarativeBuildSystem.optionIconID(toolWindowID: windowID, optionID: option.id)
        let asset = WorkbenchContributionIcon.Asset(icon, resources: resources[key])
        options[option.id] = asset
        return asset
    }
}
