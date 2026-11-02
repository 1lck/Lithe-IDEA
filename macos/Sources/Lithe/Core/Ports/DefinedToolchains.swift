import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Native evidence accepted for one consumer operation, independent of settings UI.
struct ResolvedDefinedToolchain: Sendable {
    let executable: URL
    let environment: [String: String]
    let projectCode: Bool
    let version: String?
}

/// Installation dependencies consume version and exports; they do not invoke
/// the definition's entry-launch recipe. Direct executable consumers do.
enum DefinedToolchainUse: Sendable, Equatable { case executable, installation }

@MainActor
protocol DefinedToolchainResolving: AnyObject {
    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool) async throws -> ResolvedDefinedToolchain?
    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection?) async throws -> ResolvedDefinedToolchain?
    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection?, use: DefinedToolchainUse) async throws -> ResolvedDefinedToolchain?
}

extension DefinedToolchainResolving {
    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection?, use: DefinedToolchainUse) async throws -> ResolvedDefinedToolchain? {
        try await resolve(tool: tool, directory: directory, workspace: workspace, environment: environment,
                          minimumVersion: minimumVersion, projectCodeAllowed: projectCodeAllowed, fixed: fixed)
    }

    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection?) async throws -> ResolvedDefinedToolchain? {
        guard fixed == nil else { throw BuildToolResolutionError(L10n.string("The selected toolchain is unavailable."), terminal: true) }
        return try await resolve(tool: tool, directory: directory, workspace: workspace, environment: environment,
                                 minimumVersion: minimumVersion, projectCodeAllowed: projectCodeAllowed)
    }
}
