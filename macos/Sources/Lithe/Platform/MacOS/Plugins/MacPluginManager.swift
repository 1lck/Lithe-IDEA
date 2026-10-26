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
    /// Plugins the host applies at runtime, without a restart. A plugin lives
    /// there only when every contribution has a runtime backend
    /// (`canActivateWithoutRestart`) and the module graph never held it.
    private let livePlugins: MacLivePluginRegistry?
    private let hostVersion: PluginVersion
    private let allowsLocalDevelopmentPackages: Bool
    /// Release pages before their package is replaced or their owner is disabled.
    private let invalidateWebPages: (PluginID) -> Void
    private let enableWebPages: (PluginID) -> Void
    /// Unlike disablement, package mutation blocks pages until process restart.
    private let beforePackageReplacement: (PluginID) -> Void
    /// Rust Core's install review of a package's `plugin.json`, so Settings
    /// shows the same programs the install confirmation listed.
    private let reviewPrograms: (_ manifest: Data, _ id: PluginID, _ version: PluginVersion) throws -> [PluginProgram]
    /// Reviewed programs per installed package directory, version, and
    /// content digest; views read `snapshots` often, and a reinstall of the
    /// same version changes the digest.
    private var reviewedPrograms: [String: [PluginProgram]?] = [:]
    /// Rust Core's expansion of a manifest's `workspaceConfiguration` with
    /// the given global and project values.
    private let expandWorkspaceConfiguration: WorkspaceConfigurationExpansion
    /// Looks for the program a plugin's debug adapter launches, for the settings
    /// that name it. nil when the adapter declares no lookup.
    private let lookUpDebugExecutable: DebugExecutableLookupHandler
    private var installedPlugins: [PluginID: InstalledPluginPackage]
    var settingsProjectRootURL: URL?
    var settingsActiveFileURL: URL?
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
        beforePackageReplacement: ((PluginID) -> Void)? = nil,
        reviewPrograms: @escaping (_ manifest: Data, _ id: PluginID, _ version: PluginVersion) throws -> [PluginProgram] = { _, _, _ in [] },
        expandWorkspaceConfiguration: @escaping WorkspaceConfigurationExpansion = { _, _, _, _ in nil },
        lookUpDebugExecutable: @escaping DebugExecutableLookupHandler = { _, _, _, _ in nil },
        livePlugins: MacLivePluginRegistry? = nil
    ) {
        self.livePlugins = livePlugins
        self.reviewPrograms = reviewPrograms
        self.lookUpDebugExecutable = lookUpDebugExecutable
        self.expandWorkspaceConfiguration = expandWorkspaceConfiguration
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
                .withDeclaration(
                    capabilities: PluginCapability.capabilities(of: $0.manifest, descriptor: $0.descriptor),
                    permissions: $0.descriptor.permissions,
                    programs: programs(of: $0),
                    previousVersion: $0.installation.previousVersion
                )
                .withContributions(Self.contributions(of: $0.descriptor))
                .withSettingDiscoveries(settingDiscoveries(of: $0))
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
            .withDeclaration(
                capabilities: PluginCapability.capabilities(of: $0, descriptor: nil),
                permissions: [],
                programs: nil,
                previousVersion: nil
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
        // plugin is enabled or disabled live. A plugin installed after launch
        // waits for the next module graph unless the host applies it at runtime.
        let isLive = installedPlugins[pluginID].map { appliesLive($0.descriptor) } ?? false
        if manifest.entrypoint.kind == .declarative, !registeredPluginIDs.contains(pluginID), !isLive {
            restartRequiredPluginIDs.insert(pluginID)
        }
        if isLive { livePlugins?.enablementDidChange() }
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
        try install(candidate: packageURL) { [packageStore, beforePackageReplacement] deferActivation in
            try packageStore.installPackage(
                from: packageURL,
                deferActivationUntilRestart: deferActivation,
                // Reinstalling the active version repairs a damaged or retired
                // package; a new version is installed beside the current one.
                replaceExisting: true,
                origin: origin,
                marketplace: provenance,
                beforeReplacingPackage: beforePackageReplacement
            )
        }
    }

    func installDiskPackage(at packageURL: URL, provenance: PluginDiskProvenance) throws {
        try install(candidate: packageURL) { [packageStore, beforePackageReplacement] deferActivation in
            try packageStore.installPackage(
                from: packageURL,
                deferActivationUntilRestart: deferActivation,
                replaceExisting: true,
                origin: .community,
                disk: provenance,
                beforeReplacingPackage: beforePackageReplacement
            )
        }
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
        try install(candidate: packageURL) { [packageStore, beforePackageReplacement] deferActivation in
            try packageStore.installPackage(
                from: packageURL,
                deferActivationUntilRestart: deferActivation,
                replaceExisting: isDevelopmentPackage,
                origin: isDevelopmentPackage ? .localDevelopment : .marketplace,
                beforeReplacingPackage: beforePackageReplacement
            )
        }
    }

    /// Installs a package that passed its own checks. A package the host can
    /// apply at runtime is active as soon as it is installed; any other waits
    /// for the next launch, so its files must not be read as active before.
    private func install(
        candidate packageURL: URL,
        _ perform: (_ deferActivationUntilRestart: Bool) throws -> InstalledPluginPackage
    ) throws {
        let isLive = appliesLive(try packageStore.inspectPackage(at: packageURL))
        let installed = try perform(!isLive)
        defer { rescanLivePlugins(for: installed.manifest.id, appliesLive: isLive) }
        enableFirstInstallation(of: installed.manifest)
        if !isLive { restartRequiredPluginIDs.insert(installed.manifest.id) }
        try refreshInstalledPlugins()
    }

    func rollback(_ pluginID: PluginID) throws {
        // The version being restored is only known once it is read, so a live
        // plugin rolls back in place and the result decides about a restart.
        let wasLive = livePlugins?.snapshot.entries[pluginID] != nil
        let restored = try packageStore.rollback(
            pluginID, deferActivationUntilRestart: !wasLive, beforeReplacingPackage: beforePackageReplacement
        )
        let isLive = wasLive && appliesLive(restored.descriptor)
        defer { rescanLivePlugins(for: pluginID, appliesLive: isLive) }
        if !isLive { restartRequiredPluginIDs.insert(pluginID) }
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
        if appliesLive(installed.descriptor) {
            try uninstallLivePlugin(installed)
            return
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

    /// A live plugin has no module in the running graph and nothing keeps its
    /// files in use, so removal happens now instead of at the next launch.
    private func uninstallLivePlugin(_ installed: InstalledPluginPackage) throws {
        let pluginID = installed.manifest.id
        // As for any removed plugin, only an explicit "off" outlives it.
        for declaration in installed.manifest.modules
        where configurationStore.enabledState(for: declaration.manifest.id) != false {
            configurationStore.clearEnabledState(for: declaration.manifest.id)
        }
        invalidateWebPages(pluginID)
        beforePackageReplacement(pluginID)
        defer { rescanLivePlugins(for: pluginID, appliesLive: true) }
        if installed.installation.origin == .bundled {
            try packageStore.setBundledPluginRemoved(pluginID, removed: true)
        } else {
            try packageStore.uninstall(pluginID)
        }
        try refreshInstalledPlugins()
    }

    func restore(_ pluginID: PluginID) throws {
        guard let installed = installedPlugins[pluginID],
              installed.installation.status == .removed else {
            throw PluginManagerError.unknownPlugin(pluginID)
        }
        try packageStore.setBundledPluginRemoved(pluginID, removed: false)
        // A live plugin is registered again right away; any other plugin's
        // modules join the module graph at the next launch.
        let isLive = appliesLive(installed.descriptor)
        defer { rescanLivePlugins(for: pluginID, appliesLive: isLive) }
        if !isLive { restartRequiredPluginIDs.insert(pluginID) }
        try refreshInstalledPlugins()
    }

    /// Whether a change to this package takes effect without a restart.
    private func appliesLive(_ descriptor: DeclarativePluginDescriptor) -> Bool {
        livePlugins != nil
            && descriptor.canActivateWithoutRestart
            && !registeredPluginIDs.contains(descriptor.id)
    }

    /// The registry follows the packages on disk, so a change to a plugin it
    /// holds, or may now hold, needs a rescan, which also reaches the other
    /// windows.
    private func rescanLivePlugins(for pluginID: PluginID, appliesLive: Bool) {
        guard let livePlugins, appliesLive || livePlugins.snapshot.entries[pluginID] != nil else { return }
        livePlugins.packagesDidChange()
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

    private func programs(of package: InstalledPluginPackage) -> [PluginProgram]? {
        let digest = package.installation.marketplace?.contentDigest ?? package.installation.disk?.contentDigest ?? ""
        let key = "\(package.packageURL.standardizedFileURL.path)@\(package.manifest.version)#\(digest)"
        if let cached = reviewedPrograms[key] { return cached }
        let programs = try? reviewPrograms(
            Data(contentsOf: package.packageURL.appendingPathComponent("plugin.json")),
            package.manifest.id,
            package.manifest.version
        )
        reviewedPrograms[key] = .some(programs)
        return programs
    }

    private func settingStates(
        _ declarations: [DeclarativePluginSetting],
        pluginID: PluginID
    ) -> [PluginSettingState] {
        guard !declarations.isEmpty else { return [] }
        let stored = settings.values(forPlugin: pluginID.rawValue)
        let project = settingsProjectRootURL.map {
            settings.projectValues(forPlugin: pluginID.rawValue, projectRoot: $0)
        } ?? [:]
        return declarations.map {
            PluginSettingState.resolve($0, global: stored[$0.id], project: project[$0.id])
        }
    }

    /// What the host finds for each setting that names a debug program, by
    /// setting ID. A plugin that is not installed has nothing to look for.
    private func settingDiscoveries(of package: InstalledPluginPackage) -> [String: DebugExecutableLookup] {
        guard package.installation.status == .installed else { return [:] }
        var discoveries: [String: DebugExecutableLookup] = [:]
        for adapter in package.descriptor.debugAdapters {
            guard let settingID = adapter.launchExecutableSettingID, discoveries[settingID] == nil,
                  let lookup = lookUpDebugExecutable(
                    package,
                    adapter.id,
                    settingsProjectRootURL,
                    settingsActiveFileURL?.standardizedFileURL.path
                  )
            else { continue }
            discoveries[settingID] = lookup
        }
        return discoveries
    }

    typealias DebugExecutableLookupHandler = (
        _ plugin: InstalledPluginPackage,
        _ adapterID: String,
        _ workspaceRootURL: URL?,
        _ targetPath: String?
    ) -> DebugExecutableLookup?

    private static func contributions(of descriptor: DeclarativePluginDescriptor) -> PluginSettingsContributions {
        PluginSettingsContributions(
            languages: descriptor.languages,
            languageServerIDs: descriptor.languageServers.map(\.languageID),
            buildSystems: descriptor.buildSystems.map { .init(id: $0.id, displayName: $0.displayName) },
            actions: descriptor.settingActions
        )
    }

    typealias WorkspaceConfigurationExpansion = (
        _ manifest: Data,
        _ languageID: String,
        _ global: [String: ToolingJSONValue],
        _ project: [String: ToolingJSONValue]
    ) throws -> ToolingJSONValue?

    func workspaceConfiguration(forPlugin pluginID: PluginID, languageID: String) -> ToolingJSONValue? {
        guard let package = installedPlugins[pluginID],
              let manifest = try? Data(contentsOf: package.packageURL.appendingPathComponent("plugin.json"))
        else { return nil }
        let project = settingsProjectRootURL.map {
            settings.projectValues(forPlugin: pluginID.rawValue, projectRoot: $0)
        } ?? [:]
        return try? expandWorkspaceConfiguration(
            manifest, languageID, settings.values(forPlugin: pluginID.rawValue), project
        )
    }

    func setSetting(_ value: ToolingJSONValue?, id settingID: String, for pluginID: PluginID) throws {
        try setSetting(value, id: settingID, for: pluginID, layer: .global)
    }

    func setSetting(
        _ value: ToolingJSONValue?,
        id settingID: String,
        for pluginID: PluginID,
        layer: PluginSettingLayer
    ) throws {
        guard let declaration = installedPlugins[pluginID]?.descriptor.settings.first(where: { $0.id == settingID })
        else { throw PluginManagerError.unknownSetting(pluginID, settingID) }
        if let value, !declaration.accepts(value) {
            throw PluginManagerError.settingValueRejected(pluginID, settingID)
        }
        switch layer {
        case .global:
            // A value equal to the default is forgotten, so a later change of the
            // declared default reaches users who never picked a value.
            settings.setValue(value == declaration.defaultValue ? nil : value, forSetting: settingID, plugin: pluginID.rawValue)
        case .project:
            guard declaration.scope == .project, let root = settingsProjectRootURL else {
                throw PluginManagerError.projectSettingUnavailable(pluginID, settingID)
            }
            // A project override is kept even when it equals the default: it
            // pins the value for the team regardless of their global choice.
            try settings.setProjectValue(value, forSetting: settingID, plugin: pluginID.rawValue, projectRoot: root)
        }
    }
}

enum PluginManagerError: Error, Equatable, LocalizedError {
    case unknownPlugin(PluginID)
    case unsupportedInstallationOrigin(PluginInstallationOrigin)
    case requiredPluginCannotBeDisabled(PluginID)
    case requiredPluginCannotBeUninstalled(PluginID)
    case unknownSetting(PluginID, String)
    case settingValueRejected(PluginID, String)
    case projectSettingUnavailable(PluginID, String)

    var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id): L10n.string("Plugin \(id) is not installed.")
        case .unsupportedInstallationOrigin(let origin): L10n.string("Marketplace packages cannot be installed as \(origin.rawValue).")
        case .requiredPluginCannotBeDisabled(let id): L10n.string("Required plugin \(id) cannot be disabled.")
        case .requiredPluginCannotBeUninstalled(let id): L10n.string("Required plugin \(id) cannot be uninstalled.")
        case .unknownSetting(let id, let setting): L10n.string("Plugin \(id) has no setting \(setting).")
        case .settingValueRejected(let id, let setting): L10n.string("The value is not allowed for setting \(setting) of plugin \(id).")
        case .projectSettingUnavailable(let id, let setting): L10n.string("Setting \(setting) of plugin \(id) cannot be set for this project.")
        }
    }
}
