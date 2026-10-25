import LitheCoreContracts
import LitheModuleAPI
import SwiftUI

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

extension WorkbenchModuleUIRegistry {
    /// The tool windows of one plugin's VCS providers. Every provider gets
    /// the same window; the contribution's visibility keys say which VCS it
    /// lists, so no plugin or VCS name appears here.
    static func vcsProviderRegistration(_ declaration: PluginModuleDeclaration) -> Registration {
        let owner = declaration.manifest.id
        var actions: [Action] = []
        var renderers: [Renderer] = []
        for window in declaration.contributions where window.kind == .toolWindow {
            guard let actionID = window.actionID, let rendererID = window.rendererID,
                  let pluginID = window.visibility[DeclarativeVcsProvider.pluginIDKey],
                  let vcs = window.visibility[DeclarativeVcsProvider.vcsKey] else { continue }
            let tool = WorkbenchFeatureModel.ToolWindow(rawValue: window.id)
            // Detection already ran when the workspace opened; opening the
            // window only makes sure it ran for this workspace.
            let activate: @MainActor (AppModel) async -> Bool = { model in
                do {
                    _ = try await model.services.moduleRuntime.activate(owner)
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) { model.showNotification(error.localizedDescription) }
                    return false
                }
                guard !Task.isCancelled, let workspaceURL = model.workspaceURL else { return false }
                model.loadVcsProviders(at: workspaceURL)
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
                id: rendererID, ideaAssetPath: "expui/toolwindows/vcs@20x20.svg",
                isVisible: { $0.workspaceURL != nil },
                isSelected: { $0.workbenchFeature.isVisible(tool) },
                content: { model in
                    // The feature exists when a VCS plugin was installed at
                    // launch; one installed later needs a restart.
                    guard let feature = model.vcsProvidersFeature else {
                        return AnyView(VcsProviderUnavailableView(title: window.title))
                    }
                    return AnyView(VcsProviderToolWindowView(
                        feature: feature, title: window.title, pluginID: pluginID, vcs: vcs,
                        actions: VcsProviderToolWindowActions(
                            // A root may hold the workspace, so its files can lie outside it.
                            openFile: { [weak model] url in model?.openFile(url, allowsOutsideWorkspace: true) },
                            revealInFinder: { [weak model] url in model?.revealProjectItemInFinder(url) },
                            copyPath: { [weak model] url in model?.copyProjectItemPath(url, relative: false) },
                            hide: { [weak model] in model?.workbenchFeature.setVisibility(tool, isVisible: false) }
                        )
                    ))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.vcsProvidersFeature) },
                rightSidebarBehavior: .docked,
                help: window.title
            ))
        }
        return Registration(contributions: declaration.contributions, actions: actions, renderers: renderers)
    }
}

private struct VcsProviderUnavailableView: View {
    let title: String

    var body: some View {
        Text(String(format: L10n.string("Restart Lithe to use %@."), title))
            .font(LitheTheme.uiFont(size: 12))
            .foregroundStyle(LitheTheme.secondaryText)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .litheWorkbenchSurface(LitheTheme.editor)
    }
}
