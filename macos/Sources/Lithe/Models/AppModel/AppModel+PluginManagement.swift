import Foundation
import LitheModuleAPI

extension AppModel {
    func pluginToolchainFeature(for pluginID: PluginID) -> PluginToolchainFeatureModel? {
        guard services.pluginToolchainManager.snapshot(for: pluginID) != nil else { return nil }
        if let feature = pluginToolchainFeatures[pluginID] { return feature }
        let feature = PluginToolchainFeatureModel(
            pluginID: pluginID,
            manager: services.pluginToolchainManager
        )
        pluginToolchainFeatures[pluginID] = feature
        return feature
    }

    func choosePluginToolchainPath(for pluginID: PluginID) {
        guard let directory = platformUI.chooseDirectory(
            title: NSLocalizedString("Choose Toolchain", comment: "Plugin toolchain directory picker title"),
            prompt: NSLocalizedString("Choose", comment: "Directory picker action")
        ) else { return }
        Task { @MainActor in
            if let feature = pluginToolchainFeature(for: pluginID),
               let error = await feature.setToolchainPath(directory.path) {
                showNotification(error)
            }
            objectWillChange.send()
        }
    }

    func downloadPluginToolchain(for pluginID: PluginID) async {
        if let feature = pluginToolchainFeature(for: pluginID),
           let error = await feature.downloadLatestToolchain() {
            showNotification(error)
        }
        objectWillChange.send()
    }

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

    func downloadPHPPlugin() async {
        do {
            try await services.pluginManager.download(pluginID: OfficialPluginCatalog.phpPluginID)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func reinstallPHPPlugin() async {
        do {
            try await services.pluginManager.reinstall(pluginID: OfficialPluginCatalog.phpPluginID)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func uninstallPHPPlugin() async {
        await uninstallPlugin(OfficialPluginCatalog.phpPluginID)
    }

    func uninstallPlugin(_ pluginID: PluginID) async {
        do {
            try await services.pluginManager.uninstall(pluginID)
            try services.pluginToolchainManager.removeManagedState(for: pluginID)
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
