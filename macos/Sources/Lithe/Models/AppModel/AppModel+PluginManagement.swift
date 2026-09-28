import Foundation
import LitheModuleAPI

extension AppModel {
    var pluginSnapshots: [PluginManagementSnapshot] {
        services.pluginManager.snapshots
    }

    var pluginManagementIssues: [PluginManagementIssue] {
        services.pluginManager.issues
    }

    func installPHPPluginPackage() {
        guard let packageURL = platformUI.chooseDirectory(
            title: NSLocalizedString("Install PHP Support Plugin", comment: "PHP plugin package picker title"),
            prompt: "Install"
        ) else { return }
        do {
            let manifestURL = packageURL.appendingPathComponent("plugin.json")
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.id == OfficialPluginCatalog.phpPluginID else {
                showNotification(NSLocalizedString("Select a PHP Support plugin package.", comment: "Wrong plugin package selected"))
                return
            }
            try services.pluginManager.installPackage(at: packageURL)
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

    func rollbackPlugin(_ pluginID: PluginID) {
        do {
            try services.pluginManager.rollback(pluginID)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

}
