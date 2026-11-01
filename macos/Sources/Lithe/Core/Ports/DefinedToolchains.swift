import Foundation

/// Native evidence accepted for one consumer operation, independent of settings UI.
struct ResolvedDefinedToolchain: Sendable {
    let executable: URL
    let environment: [String: String]
    let projectCode: Bool
    let version: String?
}

@MainActor
protocol DefinedToolchainResolving: AnyObject {
    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool) async throws -> ResolvedDefinedToolchain?
}
