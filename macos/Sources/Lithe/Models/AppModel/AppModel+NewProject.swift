import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 新建项目向导与项目生成器见 .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

@MainActor
extension AppModel {
    var canCreateProjects: Bool { services.projectGeneration != nil }

    func showNewProject() {
        guard canCreateProjects else {
            chooseProject(title: "New Project", prompt: "Choose Folder")
            return
        }
        workbenchFeature.isNewProjectPresented = true
    }

    /// The state of one New Project window; nil when the platform does not
    /// create projects.
    func makeNewProjectFeature() -> NewProjectFeatureModel? {
        guard let service = services.projectGeneration else { return nil }
        let runtime = services.projectRuntimeService
        return NewProjectFeatureModel(environment: NewProjectEnvironment(
            sources: { [weak self] in self?.services.projectGeneratorSources?() ?? [] },
            iconResources: services.pluginUIIconResources,
            javaRuntimes: { await runtime.discoverJavaRuntimesForNewProject() },
            service: service,
            setPluginEnabled: { [weak self] pluginID in
                try await self?.services.pluginManager.setEnabled(true, for: pluginID)
            },
            openMarketplace: { [weak self] query in self?.showPluginMarketplace(searching: query) },
            openProject: { [weak self] project in self?.openCreatedProject(project) },
            store: services.store
        ))
    }

    /// Opens plugin management on the Marketplace tab, searching for `query`.
    func showPluginMarketplace(searching query: String) {
        UserDefaults.standard.set(PluginManagementView.Tab.marketplace.rawValue, forKey: "lithe.settings.pluginTab")
        pluginMarketplaceFeature.requestedSearch = query
        showSettings(category: .plugins)
    }

    /// Opens a project the New Project window created. The files its
    /// generator names become the project's first open tabs, through the
    /// same session restore every project uses, so they open in whichever
    /// window the project lands in.
    func openCreatedProject(_ project: CreatedProject) {
        if !project.openFiles.isEmpty, services.workspaceSessionStore.load(for: project.url) == nil {
            let paths = project.openFiles.map(\.standardizedFileURL.path)
            services.workspaceSessionStore.save(
                WorkspaceSession(
                    openPaths: paths,
                    activePath: paths.first,
                    selectedSidebar: SidebarDestination.project.rawValue
                ),
                for: project.url
            )
        }
        if let warning = project.gitWarning {
            showNotification(String(format: String(localized: "The project was created, but Git could not be set up: %@"), warning))
        }
        openProject(project.url)
    }
}
