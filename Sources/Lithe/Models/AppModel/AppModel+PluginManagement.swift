import Foundation
import LitheModuleAPI

extension AppModel {
    var pluginSnapshots: [PluginManagementSnapshot] {
        services.pluginManager.snapshots
    }

    var pluginManagementIssues: [PluginManagementIssue] {
        services.pluginManager.issues
    }

    func setPluginEnabled(_ enabled: Bool, pluginID: PluginID) {
        Task { @MainActor in
            do {
                try await services.pluginManager.setEnabled(enabled, for: pluginID)
                objectWillChange.send()
            } catch {
                showNotification(error.localizedDescription)
            }
        }
    }

    func installPluginPackage() {
        guard let packageURL = platformUI.chooseDirectory(
            title: "Install Plugin Package",
            prompt: "Install"
        ) else { return }
        do {
            try services.pluginManager.installPackage(at: packageURL)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func rollbackPlugin(_ pluginID: PluginID) {
        do {
            try services.pluginManager.rollback(pluginID)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func uninstallPlugin(_ pluginID: PluginID) {
        Task { @MainActor in
            do {
                try await services.pluginManager.uninstall(pluginID)
                objectWillChange.send()
            } catch {
                showNotification(error.localizedDescription)
            }
        }
    }
}
