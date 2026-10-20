import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// A plugin setting together with the value the next launch will use.
struct PluginSettingState: Equatable, Sendable, Identifiable {
    let declaration: DeclarativePluginSetting
    let value: ToolingJSONValue

    var id: String { declaration.id }
    var isDefault: Bool { value == declaration.defaultValue }
}

struct PluginManagementIssue: Equatable, Sendable, Identifiable {
    let pluginID: PluginID?
    let message: String

    var id: String { "\(pluginID?.rawValue ?? "host"):\(message)" }
}

struct PluginManagementSnapshot: Equatable, Sendable, Identifiable {
    let manifest: PluginManifest
    let origin: PluginInstallationOrigin
    let installationStatus: PluginInstallationStatus
    let isEnabled: Bool
    let isRequired: Bool
    let isRunning: Bool
    let isQuarantined: Bool
    let isSuppressedBySafeMode: Bool
    let requiresRestart: Bool
    let canRollback: Bool
    let statusMessage: String
    /// Marketplace source and approvals of the active version, if any.
    let marketplace: PluginMarketplaceProvenance?
    /// Options the plugin lets the user change; empty when it declares none.
    var settings: [PluginSettingState] = []
    var disk: PluginDiskProvenance? = nil
    /// Something changed in this session (install, update, uninstall, …) that
    /// only a restart applies. Unlike `requiresRestart`, a bundled plugin the
    /// user removed in an earlier session does not count.
    var hasChangesPendingRestart = false

    var id: PluginID { manifest.id }
}

@MainActor
protocol PluginManaging: AnyObject {
    var snapshots: [PluginManagementSnapshot] { get }
    var issues: [PluginManagementIssue] { get }

    func setEnabled(_ enabled: Bool, for pluginID: PluginID) async throws
    /// Stores the user's value of one plugin setting; `nil` restores the
    /// plugin's default. The plugin's language servers read it at their next start.
    func setSetting(_ value: ToolingJSONValue?, id settingID: String, for pluginID: PluginID) throws
    /// Installs a package that the marketplace already downloaded, verified,
    /// and (for community packages) had the user confirm.
    func installMarketplacePackage(
        at packageURL: URL,
        origin: PluginInstallationOrigin,
        provenance: PluginMarketplaceProvenance
    ) throws
    /// Installs the reviewed local snapshot after explicit user approval.
    func installDiskPackage(at packageURL: URL, provenance: PluginDiskProvenance) throws
    func installPackage(at packageURL: URL) throws
    func rollback(_ pluginID: PluginID) throws
    func uninstall(_ pluginID: PluginID) async throws
    /// Brings back a plugin that ships inside the application after the user
    /// removed it.
    func restore(_ pluginID: PluginID) throws
}
