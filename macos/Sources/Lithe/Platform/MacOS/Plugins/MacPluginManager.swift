import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI

@MainActor
final class MacPluginManager: PluginManaging {
    private let packageStore: MacPluginPackageStore
    private let moduleRuntime: ModuleRuntime
    private let configurationStore: MacModuleConfigurationStore
    private let settings: any PluginSettingsStoring
    private let launchMode: ModuleLaunchMode
    private let managedBuiltInPlugins: [PluginManifest]
    /// Plugins whose host-owned modules were registered at launch. Their
    /// enablement changes apply immediately; anything installed later needs
    /// a restart to join the module graph.
    private let registeredPluginIDs: Set<PluginID>
    private let hostVersion: PluginVersion
    private let allowsLocalDevelopmentPackages: Bool
    /// Release pages before their package is replaced or their owner is disabled.
    private let invalidateWebPages: (PluginID) -> Void
    private let enableWebPages: (PluginID) -> Void
    /// Unlike disablement, package mutation blocks pages until process restart.
    private let beforePackageReplacement: (PluginID) -> Void
    private var installedPlugins: [PluginID: InstalledPluginPackage]
    private var restartRequiredPluginIDs: Set<PluginID> = []
    private(set) var issues: [PluginManagementIssue]

    init(
        packageStore: MacPluginPackageStore,
        moduleRuntime: ModuleRuntime,
        configurationStore: MacModuleConfigurationStore,
        settings: any PluginSettingsStoring,
        launchMode: ModuleLaunchMode,
        startup: MacPluginStartupResult,
        managedBuiltInPlugins: [PluginManifest] = [],
        hostVersion: PluginVersion = BuiltInPluginCatalog.hostVersion,
        allowsLocalDevelopmentPackages: Bool =
            MacOfficialPluginSignatureVerifier.allowsLocalDevelopmentPackagesByDefault,
        invalidateWebPages: @escaping (PluginID) -> Void = { _ in },
        enableWebPages: @escaping (PluginID) -> Void = { _ in },
        beforePackageReplacement: ((PluginID) -> Void)? = nil
    ) {
        self.packageStore = packageStore
        self.allowsLocalDevelopmentPackages = allowsLocalDevelopmentPackages
        self.invalidateWebPages = invalidateWebPages
        self.enableWebPages = enableWebPages
        self.beforePackageReplacement = beforePackageReplacement ?? invalidateWebPages
        self.moduleRuntime = moduleRuntime
        self.configurationStore = configurationStore
        self.settings = settings
        self.launchMode = launchMode
        self.managedBuiltInPlugins = managedBuiltInPlugins.sorted { $0.id < $1.id }
        self.hostVersion = hostVersion
        registeredPluginIDs = Set(startup.registeredPlugins.map(\.manifest.id))
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
                    marketplace: $0.installation.marketplace,
                    disk: $0.installation.disk,
                    settings: $0.descriptor.settings,
                    runtimeSnapshots: runtimeSnapshots
                )
            }
        let builtIn = managedBuiltInPlugins.map {
            snapshot(
                manifest: $0,
                origin: .bundled,
                installationStatus: .installed,
                previousVersion: nil,
                marketplace: nil,
                disk: nil,
                settings: [],
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

        if !enabled { invalidateWebPages(pluginID) }
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

        // Declarative plugins run no code in this process, so a registered
        // plugin is enabled or disabled live. Only a plugin installed after
        // launch waits for the next module graph.
        if manifest.entrypoint.kind == .declarative, !registeredPluginIDs.contains(pluginID) {
            restartRequiredPluginIDs.insert(pluginID)
        }
        if enabled && !restartRequiredPluginIDs.contains(pluginID) { enableWebPages(pluginID) }
    }

    func installMarketplacePackage(
        at packageURL: URL,
        origin: PluginInstallationOrigin,
        provenance: PluginMarketplaceProvenance
    ) throws {
        guard origin == .marketplace || origin == .community else {
            throw PluginManagerError.unsupportedInstallationOrigin(origin)
        }
        let installed = try packageStore.installPackage(
            from: packageURL,
            deferActivationUntilRestart: true,
            // Reinstalling the active version repairs a damaged or retired
            // package; a new version is installed beside the current one.
            replaceExisting: true,
            origin: origin,
            marketplace: provenance,
            beforeReplacingPackage: beforePackageReplacement
        )
        enableFirstInstallation(of: installed.manifest)
        restartRequiredPluginIDs.insert(installed.manifest.id)
        try refreshInstalledPlugins()
    }

    func installDiskPackage(at packageURL: URL, provenance: PluginDiskProvenance) throws {
        let installed = try packageStore.installPackage(
            from: packageURL,
            deferActivationUntilRestart: true,
            replaceExisting: true,
            origin: .community,
            disk: provenance,
            beforeReplacingPackage: beforePackageReplacement
        )
        enableFirstInstallation(of: installed.manifest)
        restartRequiredPluginIDs.insert(installed.manifest.id)
        try refreshInstalledPlugins()
    }

    func installPackage(at packageURL: URL) throws {
        // Only development builds record an unsigned package from disk as a
        // development package, and only when its trust model requires a
        // publisher signature; release builds keep the signed-package path.
        let manifest = try packageStore.inspectPackage(at: packageURL).pluginManifest
        let isDevelopmentPackage = allowsLocalDevelopmentPackages
            && MacOfficialPluginSignatureVerifier.isUnsignedDevelopmentPackage(
                at: packageURL,
                manifest: manifest
            )
        let installed = try packageStore.installPackage(
            from: packageURL,
            deferActivationUntilRestart: true,
            replaceExisting: isDevelopmentPackage,
            origin: isDevelopmentPackage ? .localDevelopment : .marketplace,
            beforeReplacingPackage: beforePackageReplacement
        )
        enableFirstInstallation(of: installed.manifest)
        restartRequiredPluginIDs.insert(installed.manifest.id)
        try refreshInstalledPlugins()
    }

    func rollback(_ pluginID: PluginID) throws {
        _ = try packageStore.rollback(
            pluginID, deferActivationUntilRestart: true, beforeReplacingPackage: beforePackageReplacement
        )
        restartRequiredPluginIDs.insert(pluginID)
        try refreshInstalledPlugins()
    }

    func uninstall(_ pluginID: PluginID) async throws {
        guard let installed = installedPlugins[pluginID] else {
            guard issues.contains(where: { $0.pluginID == pluginID }) else {
                throw PluginManagerError.unknownPlugin(pluginID)
            }
            beforePackageReplacement(pluginID)
            try packageStore.stageInvalidPackageUninstall(pluginID)
            restartRequiredPluginIDs.insert(pluginID)
            issues.removeAll { $0.pluginID == pluginID }
            issues.append(PluginManagementIssue(
                pluginID: pluginID,
                message: "Will be uninstalled after restart"
            ))
            return
        }
        guard !installed.manifest.modules.contains(where: { $0.manifest.isRequired }) else {
            throw PluginManagerError.requiredPluginCannotBeUninstalled(pluginID)
        }
        if registeredPluginIDs.contains(pluginID) {
            // Stopping the modules is not the user turning them off. Language
            // module IDs outlive the package (a later install, or the community
            // plugin that replaces a retired official one, reuses them), so keep
            // only an explicit "off" and let the next installation start fresh.
            let moduleIDs = installed.manifest.modules.map(\.manifest.id)
            let explicitlyDisabled = Set(moduleIDs.filter { configurationStore.enabledState(for: $0) == false })
            try await setEnabled(false, for: pluginID)
            for moduleID in moduleIDs where !explicitlyDisabled.contains(moduleID) {
                configurationStore.clearEnabledState(for: moduleID)
            }
        }
        beforePackageReplacement(pluginID)
        if installed.installation.origin == .bundled {
            // The package itself lives in the read-only app bundle.
            try packageStore.setBundledPluginRemoved(pluginID, removed: true)
        } else {
            try packageStore.stageUninstall(pluginID)
        }
        restartRequiredPluginIDs.insert(pluginID)
        try refreshInstalledPlugins()
    }

    func restore(_ pluginID: PluginID) throws {
        guard let installed = installedPlugins[pluginID],
              installed.installation.status == .removed else {
            throw PluginManagerError.unknownPlugin(pluginID)
        }
        try packageStore.setBundledPluginRemoved(pluginID, removed: false)
        // Its modules join the module graph at the next launch.
        restartRequiredPluginIDs.insert(pluginID)
        try refreshInstalledPlugins()
    }

    /// The user confirmed this installation, so its modules start enabled at
    /// the next launch. Module defaults stay off for packages that appear
    /// without that confirmation, and an update keeps the user's choice.
    private func enableFirstInstallation(of manifest: PluginManifest) {
        guard installedPlugins[manifest.id] == nil, !registeredPluginIDs.contains(manifest.id) else { return }
        // Language module IDs are shared across plugin IDs. A package rejected
        // for an ownership collision at restart must not first enable its owner.
        // Reserve disabled/removed packages too, and keep the running graph's
        // old modules reserved until restart even if their package was replaced.
        let existingManifests = BuiltInPluginCatalog.manifests
            + BundledLanguagePluginCatalog.manifests
            + managedBuiltInPlugins
            + installedPlugins.values.map(\.manifest)
        let ownedModuleIDs = Set(existingManifests.flatMap(\.modules).map(\.manifest.id))
            .union(moduleRuntime.snapshots().map(\.manifest.id))
        guard manifest.modules.allSatisfy({ !ownedModuleIDs.contains($0.manifest.id) }) else { return }
        for declaration in manifest.modules
        where configurationStore.enabledState(for: declaration.manifest.id) == nil {
            configurationStore.setEnabledState(true, for: declaration.manifest.id)
        }
    }

    /// A plugin removed in this session is still registered until restart.
    private func requiresRestartForRemoval(_ pluginID: PluginID) -> Bool {
        registeredPluginIDs.contains(pluginID)
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
        marketplace: PluginMarketplaceProvenance?,
        disk: PluginDiskProvenance?,
        settings declaredSettings: [DeclarativePluginSetting],
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
        } else if installationStatus == .removed {
            statusMessage = requiresRestartForRemoval(manifest.id)
                ? "Removed. Restart Lithe to finish."
                : "Removed. Restore it to use it again."
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
            statusMessage: statusMessage,
            marketplace: marketplace,
            settings: settingStates(declaredSettings, pluginID: manifest.id),
            disk: disk,
            hasChangesPendingRestart: restartRequiredPluginIDs.contains(manifest.id)
                || installationStatus == .uninstallPending
        )
    }

    private func settingStates(
        _ declarations: [DeclarativePluginSetting],
        pluginID: PluginID
    ) -> [PluginSettingState] {
        guard !declarations.isEmpty else { return [] }
        let stored = settings.values(forPlugin: pluginID.rawValue)
        return declarations.map {
            PluginSettingState(declaration: $0, value: $0.effectiveValue(stored: stored[$0.id]))
        }
    }

    func setSetting(_ value: ToolingJSONValue?, id settingID: String, for pluginID: PluginID) throws {
        guard let declaration = installedPlugins[pluginID]?.descriptor.settings.first(where: { $0.id == settingID })
        else { throw PluginManagerError.unknownSetting(pluginID, settingID) }
        if let value, !declaration.accepts(value) {
            throw PluginManagerError.settingValueRejected(pluginID, settingID)
        }
        // A value equal to the default is forgotten, so a later change of the
        // declared default reaches users who never picked a value.
        settings.setValue(value == declaration.defaultValue ? nil : value, forSetting: settingID, plugin: pluginID.rawValue)
    }
}

enum PluginManagerError: Error, Equatable, LocalizedError {
    case unknownPlugin(PluginID)
    case unsupportedInstallationOrigin(PluginInstallationOrigin)
    case requiredPluginCannotBeDisabled(PluginID)
    case requiredPluginCannotBeUninstalled(PluginID)
    case unknownSetting(PluginID, String)
    case settingValueRejected(PluginID, String)

    var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id): "Plugin \(id) is not installed."
        case .unsupportedInstallationOrigin(let origin): "Marketplace packages cannot be installed as \(origin.rawValue)."
        case .requiredPluginCannotBeDisabled(let id): "Required plugin \(id) cannot be disabled."
        case .requiredPluginCannotBeUninstalled(let id): "Required plugin \(id) cannot be uninstalled."
        case .unknownSetting(let id, let setting): "Plugin \(id) has no setting \(setting)."
        case .settingValueRejected(let id, let setting): "The value is not allowed for setting \(setting) of plugin \(id)."
        }
    }
}
