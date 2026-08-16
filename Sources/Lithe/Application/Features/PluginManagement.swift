import Foundation
import LitheModuleAPI

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

    var id: PluginID { manifest.id }
}

@MainActor
protocol PluginManaging: AnyObject {
    var snapshots: [PluginManagementSnapshot] { get }
    var issues: [PluginManagementIssue] { get }

    func setEnabled(_ enabled: Bool, for pluginID: PluginID) async throws
    func installPackage(at packageURL: URL) throws
    func rollback(_ pluginID: PluginID) throws
    func uninstall(_ pluginID: PluginID) async throws
}
