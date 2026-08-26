import Foundation
import LitheModuleAPI

extension AppModel {
    var pluginSnapshots: [PluginManagementSnapshot] {
        services.pluginManager.snapshots
    }

    var pluginManagementIssues: [PluginManagementIssue] {
        services.pluginManager.issues
    }

    func applyPluginEnabledChanges(_ changes: [PluginID: Bool]) async -> Set<PluginID> {
        let snapshotsByID = Dictionary(uniqueKeysWithValues: pluginSnapshots.map { ($0.id, $0) })
        let closesDatabase = changes.contains { pluginID, enabled in
            !enabled && snapshotsByID[pluginID]?.manifest.modules.contains {
                $0.manifest.id == .database
            } == true
        }
        if closesDatabase, selectedSidebar == .database {
            selectedSidebar = .project
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
        objectWillChange.send()
        return appliedPluginIDs
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
