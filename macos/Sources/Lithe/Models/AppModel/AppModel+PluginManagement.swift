import Foundation
import LitheCoreContracts
import LitheModuleAPI

extension AppModel {
    var pluginSnapshots: [PluginManagementSnapshot] {
        services.pluginManager.snapshots
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
            closeStalePluginWebPages()
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func applyPluginEnabledChanges(_ changes: [PluginID: Bool]) async -> Set<PluginID> {
        let snapshotsByID = Dictionary(uniqueKeysWithValues: pluginSnapshots.map { ($0.id, $0) })
        let closesDatabase = changes.contains { pluginID, enabled in
            !enabled && snapshotsByID[pluginID]?.manifest.modules.contains {
                $0.manifest.id == .database
            } == true
        }
        if closesDatabase {
            closeDatabaseWorkspace()
            workbenchFeature.setVisibility(.database, isVisible: false)
            await Task.yield()
        }

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
            closeStalePluginWebPages()
        }
        objectWillChange.send()
        return appliedPluginIDs
    }

    /// Stores the user's value of a plugin setting; `nil` restores the plugin's
    /// default. The plugin's language servers read it when they next start.
    func setPluginSetting(_ value: ToolingJSONValue?, id settingID: String, for pluginID: PluginID) {
        do {
            try services.pluginManager.setSetting(value, id: settingID, for: pluginID)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
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
