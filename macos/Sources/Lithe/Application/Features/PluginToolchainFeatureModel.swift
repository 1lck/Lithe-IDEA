import Combine
import Foundation
import LitheModuleAPI

struct PluginToolchainSnapshot: Equatable, Sendable {
    let pluginID: PluginID
    let displayName: String
    let canInstallLanguageServer: Bool
    let state: State
    let selectedPath: String?
    let selectedVersion: String?

    enum State: Equatable, Sendable {
        case missing
        case checking
        case configured(path: String, version: String?)
        case downloading
        case installingServer
        case failed(String)
    }
}

@MainActor
protocol PluginToolchainManaging: AnyObject {
    var snapshots: [PluginID: PluginToolchainSnapshot] { get }

    func snapshot(for pluginID: PluginID) -> PluginToolchainSnapshot?
    func setToolchainPath(_ path: String, for pluginID: PluginID) async throws
    func downloadLatestToolchain(for pluginID: PluginID) async throws
    func installLanguageServer(for pluginID: PluginID) async throws
    func removeManagedState(for pluginID: PluginID) throws
}

@MainActor
final class UnavailablePluginToolchainManager: PluginToolchainManaging {
    var snapshots: [PluginID: PluginToolchainSnapshot] { [:] }
    func snapshot(for _: PluginID) -> PluginToolchainSnapshot? { nil }
    func setToolchainPath(_: String, for _: PluginID) async throws { throw PluginToolchainError.unavailable }
    func downloadLatestToolchain(for _: PluginID) async throws { throw PluginToolchainError.unavailable }
    func installLanguageServer(for _: PluginID) async throws { throw PluginToolchainError.unavailable }
    func removeManagedState(for _: PluginID) throws {}
}

@MainActor
final class PluginToolchainFeatureModel: ObservableObject {
    @Published private(set) var snapshot: PluginToolchainSnapshot

    private let pluginID: PluginID
    private let manager: any PluginToolchainManaging

    init(pluginID: PluginID, manager: any PluginToolchainManaging) {
        self.pluginID = pluginID
        self.manager = manager
        snapshot = manager.snapshot(for: pluginID) ?? PluginToolchainSnapshot(
            pluginID: pluginID,
            displayName: "Toolchain",
            canInstallLanguageServer: false,
            state: .missing,
            selectedPath: nil,
            selectedVersion: nil
        )
    }

    func setToolchainPath(_ path: String) async -> String? {
        await perform(state: .checking) { try await manager.setToolchainPath(path, for: pluginID) }
    }

    func downloadLatestToolchain() async -> String? {
        await perform(state: .downloading) { try await manager.downloadLatestToolchain(for: pluginID) }
    }

    func installLanguageServer() async -> String? {
        await perform(state: .installingServer) { try await manager.installLanguageServer(for: pluginID) }
    }

    private func perform(state: PluginToolchainSnapshot.State, _ operation: () async throws -> Void) async -> String? {
        switch snapshot.state {
        case .checking, .downloading, .installingServer: return PluginToolchainError.busy.localizedDescription
        default: break
        }
        snapshot = PluginToolchainSnapshot(
            pluginID: snapshot.pluginID, displayName: snapshot.displayName,
            canInstallLanguageServer: snapshot.canInstallLanguageServer, state: state,
            selectedPath: snapshot.selectedPath, selectedVersion: snapshot.selectedVersion
        )
        do {
            try await operation()
            snapshot = manager.snapshot(for: pluginID) ?? snapshot
            return nil
        } catch {
            snapshot = manager.snapshot(for: pluginID) ?? snapshot
            return error.localizedDescription
        }
    }
}

enum PluginToolchainError: LocalizedError, Equatable {
    case unavailable
    case busy
    case invalidToolchainPath(String)
    case validationFailed(String)
    case downloadMetadataFailed
    case noSupportedToolchain
    case downloadFailed
    case checksumMismatch
    case extractionFailed(String)
    case languageServerInstallationFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            "A toolchain operation is already running. Please wait for it to finish."
        case .unavailable:
            "Toolchain management is unavailable in this environment."
        case .invalidToolchainPath(let path):
            "The selected path is not a valid toolchain: \(path)"
        case .validationFailed(let message):
            "The selected toolchain could not be validated: \(message)"
        case .downloadMetadataFailed:
            "The official toolchain download index could not be loaded."
        case .noSupportedToolchain:
            "No supported toolchain archive was found for this Mac."
        case .downloadFailed:
            "The toolchain could not be downloaded."
        case .checksumMismatch:
            "The downloaded toolchain failed its SHA-256 check."
        case .extractionFailed(let message):
            "The downloaded toolchain could not be installed: \(message)"
        case .languageServerInstallationFailed(let message):
            "The language server could not be installed with the selected toolchain: \(message)"
        }
    }
}
