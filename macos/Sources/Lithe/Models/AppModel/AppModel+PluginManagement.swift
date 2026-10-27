import Foundation
import LitheCoreContracts
import LitheModuleAPI

extension AppModel {
    var pluginSnapshots: [PluginManagementSnapshot] {
        // Project-scoped plugin settings show the open project's overrides.
        if services.pluginManager.settingsProjectRootURL != workspaceURL {
            services.pluginManager.settingsProjectRootURL = workspaceURL
        }
        // A setting that names the program built from the open file looks for it here.
        let activeFileURL = activeDocument?.url
        if services.pluginManager.settingsActiveFileURL != activeFileURL {
            services.pluginManager.settingsActiveFileURL = activeFileURL
        }
        return services.pluginManager.snapshots
    }

    var pluginManagementIssues: [PluginManagementIssue] {
        services.pluginManager.issues
    }

    /// Reviews a private snapshot of the selected ZIP or directory. Community
    /// packages wait for the same explicit permission sheet as market installs.
    func installPluginPackageFromDisk() async {
        guard let packageURL = platformUI.choosePluginPackage(
            title: PluginMarketplacePresentation.localized("Install Plugin from Disk", locale: settings.language.locale),
            prompt: PluginMarketplacePresentation.localized("Choose Plugin Package", locale: settings.language.locale)
        ) else { return }
        await pluginMarketplaceFeature.installFromDisk(at: packageURL)
        closeStalePluginWebPages()
        objectWillChange.send()
    }

    func restorePlugin(_ pluginID: PluginID) {
        do {
            try services.pluginManager.restore(pluginID)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func uninstallPlugin(_ pluginID: PluginID) async {
        do {
            try await services.pluginManager.uninstall(pluginID)
            buildSystemsFeatureIfActive?.pluginsChanged()
            vcsProvidersFeature?.pluginsChanged()
            closeStalePluginWebPages()
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func applyPluginEnabledChanges(_ changes: [PluginID: Bool]) async -> Set<PluginID> {
        var appliedPluginIDs: Set<PluginID> = []
        for pluginID in changes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let enabled = changes[pluginID] else { continue }
            do {
                try await services.pluginManager.setEnabled(enabled, for: pluginID)
                appliedPluginIDs.insert(pluginID)
            } catch {
                showNotification(error.localizedDescription)
            }
        }
        if !appliedPluginIDs.isEmpty {
            buildSystemsFeatureIfActive?.pluginsChanged()
            vcsProvidersFeature?.pluginsChanged()
            closeStalePluginWebPages()
        }
        objectWillChange.send()
        return appliedPluginIDs
    }

    func rollbackPlugin(_ pluginID: PluginID) {
        do {
            try services.pluginManager.rollback(pluginID)
            closeStalePluginWebPages()
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

}
