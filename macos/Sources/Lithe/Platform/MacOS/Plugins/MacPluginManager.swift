import Foundation
import LitheApplicationKernel
import LitheModuleAPI

@MainActor
final class MacPluginManager: PluginManaging {
    private let packageStore: MacPluginPackageStore
    private let moduleRuntime: ModuleRuntime
    private let configurationStore: MacModuleConfigurationStore
    private let launchMode: ModuleLaunchMode
    private let managedBuiltInPlugins: [PluginManifest]
    private let activeNativePluginIDs: Set<PluginID>
    private var installedPlugins: [PluginID: InstalledPluginPackage]
    private var restartRequiredPluginIDs: Set<PluginID> = []
    private(set) var issues: [PluginManagementIssue]

    init(
        packageStore: MacPluginPackageStore,
        moduleRuntime: ModuleRuntime,
        configurationStore: MacModuleConfigurationStore,
        launchMode: ModuleLaunchMode,
        startup: MacPluginStartupResult,
        managedBuiltInPlugins: [PluginManifest] = []
    ) {
        self.packageStore = packageStore
        self.moduleRuntime = moduleRuntime
        self.configurationStore = configurationStore
        self.launchMode = launchMode
        self.managedBuiltInPlugins = managedBuiltInPlugins.sorted { $0.id < $1.id }
        activeNativePluginIDs = Set(startup.activeNativeManifests.map(\.id))
        installedPlugins = Dictionary(
            uniqueKeysWithValues: startup.installedPlugins.map { ($0.manifest.id, $0) }
        )
        issues = startup.issues.map {
            PluginManagementIssue(pluginID: $0.pluginID, message: $0.message)
        }
    }

    var snapshots: [PluginManagementSnapshot] {
        let runtimeSnapshots = Dictionary(
            uniqueKeysWithValues: moduleRuntime.snapshots().map { ($0.manifest.id, $0) }
        )
        let native = installedPlugins.values
            .map {
                snapshot(
                    manifest: $0.manifest,
                    origin: $0.installation.origin,
                    installationStatus: $0.installation.status,
                    previousVersion: $0.installation.previousVersion,
                    runtimeSnapshots: runtimeSnapshots
                )
            }
        let builtIn = managedBuiltInPlugins.map {
            snapshot(
                manifest: $0,
                origin: .bundled,
                installationStatus: .installed,
                previousVersion: nil,
                runtimeSnapshots: runtimeSnapshots
            )
        }
        return (builtIn + native).sorted { $0.manifest.displayName < $1.manifest.displayName }
    }

    func setEnabled(_ enabled: Bool, for pluginID: PluginID) async throws {
        guard let manifest = manifest(for: pluginID) else {
            throw PluginManagerError.unknownPlugin(pluginID)
        }
        guard enabled || !manifest.modules.contains(where: { $0.manifest.isRequired }) else {
            throw PluginManagerError.requiredPluginCannotBeDisabled(pluginID)
        }

        let registeredIDs = Set(moduleRuntime.snapshots().map(\.manifest.id))
        let declarations: [PluginModuleDeclaration] = enabled
            ? manifest.modules
            : Array(manifest.modules.reversed())
        for declaration in declarations {
            let moduleID = declaration.manifest.id
            if registeredIDs.contains(moduleID) {
                try await moduleRuntime.setEnabled(enabled, for: moduleID)
            } else {
                configurationStore.setEnabledState(enabled, for: moduleID)
                if enabled {
                    configurationStore.setQuarantined(false, for: moduleID)
                }
            }
        }

        if manifest.entrypoint.kind == .nativeBundle,
           enabled != activeNativePluginIDs.contains(pluginID) {
            restartRequiredPluginIDs.insert(pluginID)
        } else if manifest.entrypoint.kind == .nativeBundle, !enabled {
            // The module graph is stopped immediately, but Swift Bundle code
            // remains mapped until this process exits.
            restartRequiredPluginIDs.insert(pluginID)
        }
    }

    func installPackage(at packageURL: URL) throws {
        let installed = try packageStore.installPackage(
            from: packageURL,
            deferActivationUntilRestart: true
        )
        restartRequiredPluginIDs.insert(installed.manifest.id)
        try refreshInstalledPlugins()
    }

    func rollback(_ pluginID: PluginID) throws {
        _ = try packageStore.rollback(pluginID, deferActivationUntilRestart: true)
        restartRequiredPluginIDs.insert(pluginID)
        try refreshInstalledPlugins()
    }

    func uninstall(_ pluginID: PluginID) async throws {
        guard let installed = installedPlugins[pluginID] else {
            guard issues.contains(where: { $0.pluginID == pluginID }) else {
                throw PluginManagerError.unknownPlugin(pluginID)
            }
            try packageStore.stageInvalidPackageUninstall(pluginID)
            restartRequiredPluginIDs.insert(pluginID)
            issues.removeAll { $0.pluginID == pluginID }
            issues.append(PluginManagementIssue(
                pluginID: pluginID,
                message: "Will be uninstalled after restart"
            ))
            return
        }
        if activeNativePluginIDs.contains(pluginID) {
            try await setEnabled(false, for: pluginID)
        }
        guard !installed.manifest.modules.contains(where: { $0.manifest.isRequired }) else {
            throw PluginManagerError.requiredPluginCannotBeUninstalled(pluginID)
        }
        try packageStore.stageUninstall(pluginID)
        restartRequiredPluginIDs.insert(pluginID)
        try refreshInstalledPlugins()
    }

    private func manifest(for pluginID: PluginID) -> PluginManifest? {
        installedPlugins[pluginID]?.manifest
            ?? managedBuiltInPlugins.first { $0.id == pluginID }
    }

    private func refreshInstalledPlugins() throws {
        let scan = try packageStore.scanInstalledPlugins()
        installedPlugins = Dictionary(
            uniqueKeysWithValues: scan.packages.map { ($0.manifest.id, $0) }
        )
        issues = issues.filter { issue in
            guard let pluginID = issue.pluginID else { return true }
            return installedPlugins[pluginID] == nil
        } + scan.issues.map {
            PluginManagementIssue(pluginID: $0.pluginID, message: $0.message)
        }
    }

    private func snapshot(
        manifest: PluginManifest,
        origin: PluginInstallationOrigin,
        installationStatus: PluginInstallationStatus,
        previousVersion: PluginVersion?,
        runtimeSnapshots: [ModuleID: ModuleSnapshot]
    ) -> PluginManagementSnapshot {
        let moduleSnapshots = manifest.modules.compactMap { runtimeSnapshots[$0.manifest.id] }
        let isConfiguredEnabled = manifest.modules.contains { declaration in
            if let runtime = runtimeSnapshots[declaration.manifest.id] {
                return runtime.state != .disabled
            }
            return configurationStore.enabledState(for: declaration.manifest.id)
                ?? (declaration.manifest.defaultState == .enabled)
        }
        let isQuarantined = manifest.modules.contains { declaration in
            runtimeSnapshots[declaration.manifest.id]?.isQuarantined
                ?? configurationStore.isQuarantined(declaration.manifest.id)
        }
        let isEnabled = isConfiguredEnabled && !isQuarantined
        let isSuppressedBySafeMode = launchMode == .safeMode
            && !manifest.modules.contains(where: { $0.manifest.isRequired })
        let isRunning = moduleSnapshots.contains { $0.isInstantiated }
        let requiresRestart = restartRequiredPluginIDs.contains(manifest.id)
            || installationStatus != .installed
        let matchingIssue = issues.first { $0.pluginID == manifest.id }
        let statusMessage: String
        if let matchingIssue {
            statusMessage = matchingIssue.message
        } else if installationStatus == .uninstallPending {
            statusMessage = "Will be uninstalled after restart"
        } else if requiresRestart {
            statusMessage = "Restart required"
        } else if isQuarantined {
            statusMessage = "Disabled after the previous plugin session ended unexpectedly"
        } else if isSuppressedBySafeMode {
            statusMessage = "Disabled in Safe Mode"
        } else if isRunning {
            statusMessage = "Running"
        } else if isEnabled {
            statusMessage = "Enabled"
        } else {
            statusMessage = "Disabled"
        }
        return PluginManagementSnapshot(
            manifest: manifest,
            origin: origin,
            installationStatus: installationStatus,
            isEnabled: isEnabled,
            isRequired: manifest.modules.contains(where: { $0.manifest.isRequired }),
            isRunning: isRunning,
            isQuarantined: isQuarantined,
            isSuppressedBySafeMode: isSuppressedBySafeMode,
            requiresRestart: requiresRestart,
            canRollback: previousVersion != nil,
            statusMessage: statusMessage
        )
    }
}

enum PluginManagerError: Error, Equatable, LocalizedError {
    case unknownPlugin(PluginID)
    case requiredPluginCannotBeDisabled(PluginID)
    case requiredPluginCannotBeUninstalled(PluginID)

    var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id): "Plugin \(id) is not installed."
        case .requiredPluginCannotBeDisabled(let id): "Required plugin \(id) cannot be disabled."
        case .requiredPluginCannotBeUninstalled(let id): "Required plugin \(id) cannot be uninstalled."
        }
    }
}
