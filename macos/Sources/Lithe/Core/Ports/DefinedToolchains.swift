import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Native evidence accepted for one consumer operation, independent of settings UI.
struct ResolvedDefinedToolchain: Sendable {
    let executable: URL
    let environment: [String: String]
    let projectCode: Bool
    let version: String?
    /// The installation root the selection came from; the definition's `launch`
    /// template can name it as `${home}`. Nil when the tool was chosen by executable.
    var home: String? = nil
}

/// The program and arguments a tool definition's `launch` template expands to for one
/// selected installation.
struct DefinedToolLaunch: Sendable, Equatable {
    let executable: String
    let arguments: [String]
}

/// Core refused to expand a `launch` template. `code` is Core's own error code, such as
/// `plugin.toolchain.launchMismatch` when the template cannot carry what the caller supplied.
struct DefinedToolLaunchRejection: Error, Equatable, Sendable {
    let code: String
    let message: String
}

/// Turns a resolved tool installation into the argv that starts it, following the
/// definition's `launch` template, so no caller branches on a tool name.
@MainActor
protocol DefinedToolLaunching: AnyObject {
    func launch(of selection: ResolvedDefinedToolchain, tool: String, arguments: [String]) throws -> DefinedToolLaunch
}

/// Installation dependencies consume version and exports; they do not invoke
/// the definition's entry-launch recipe. Direct executable consumers do.
enum DefinedToolchainUse: Sendable, Equatable { case executable, installation }

@MainActor
protocol DefinedToolchainResolving: AnyObject {
    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection?, use: DefinedToolchainUse, consumerID: String?) async throws -> ResolvedDefinedToolchain?
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
                 fixed: FixedToolchainSelection?, use: DefinedToolchainUse, consumerID: String?) async throws -> ResolvedDefinedToolchain? {
        try await resolve(tool: tool, directory: directory, workspace: workspace, environment: environment,
                          minimumVersion: minimumVersion, projectCodeAllowed: projectCodeAllowed, fixed: fixed, use: use)
    }
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
