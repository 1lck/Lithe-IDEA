import Foundation

extension AppModel {
    func toggleToolWindow(_ toolWindow: WorkbenchFeatureModel.ToolWindow) -> Bool {
        let willShow = !workbenchFeature.isVisible(toolWindow)
        workbenchFeature.setVisibility(toolWindow, isVisible: willShow)
        return willShow
    }

    func showToolWindow(_ toolWindow: WorkbenchFeatureModel.ToolWindow) {
        workbenchFeature.setVisibility(toolWindow, isVisible: true)
    }

    var selectedSidebar: SidebarDestination {
        get { workbenchFeature.selectedSidebar }
        set { workbenchFeature.setSelectedSidebar(newValue) }
    }

    var isRunVisible: Bool {
        get { workbenchFeature.isVisible(.run) }
        set { workbenchFeature.setVisibility(.run, isVisible: newValue) }
    }

    var isTestsVisible: Bool {
        get { workbenchFeature.isVisible(.tests) }
        set { workbenchFeature.setVisibility(.tests, isVisible: newValue) }
    }

    var isGitLogVisible: Bool {
        get { workbenchFeature.isVisible(.gitLog) }
        set { workbenchFeature.setVisibility(.gitLog, isVisible: newValue) }
    }

    var isTerminalVisible: Bool {
        get { workbenchFeature.isVisible(.terminal) }
        set { workbenchFeature.setVisibility(.terminal, isVisible: newValue) }
    }

    var isReferencesVisible: Bool {
        get { workbenchFeature.isVisible(.references) }
        set { workbenchFeature.setVisibility(.references, isVisible: newValue) }
    }

    var isProblemsVisible: Bool {
        get { workbenchFeature.isVisible(.problems) }
        set { workbenchFeature.setVisibility(.problems, isVisible: newValue) }
    }

    var isSpringVisible: Bool {
        get { workbenchFeature.isVisible(.spring) }
        set { workbenchFeature.setVisibility(.spring, isVisible: newValue) }
    }

    var isDebugVisible: Bool {
        get { workbenchFeature.isVisible(.debug) }
        set { workbenchFeature.setVisibility(.debug, isVisible: newValue) }
    }

    func restoreVisibleToolModules() async {
        let workspace = workspaceURL
        await awaitModuleRuntimeShutdown()
        for tool in WorkbenchFeatureModel.ToolWindow.allCases where workbenchFeature.isVisible(tool) {
            guard !Task.isCancelled, workspaceURL == workspace else { return }
            switch tool {
            case .terminal:
                if await activateTerminalModule(), !Task.isCancelled, workspaceURL == workspace, activeTerminalSession == nil { _ = createTerminalSession() }
            case .gitLog: await refreshGitHistory()
            case .changes: _ = await activateGitModule()
            case .search: _ = await activateSearchModule()
            case .database, .databaseServices: _ = await databaseModuleCoordinator.activate()
            case .agent: activateAgentConversation()
            case .run, .tests: _ = await activateExecutionModule()
            case .buildOutput:
                if let access = await activateExecutionModule() { loadBuildSystems(access) }
            case .debug: _ = await activateDebugModule()
            default: break
            }
        }
    }

    func resetWorkbenchState() {
        workbenchFeature.reset()
    }

}
