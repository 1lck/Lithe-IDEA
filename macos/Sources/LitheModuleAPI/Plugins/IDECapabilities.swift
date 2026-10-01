import Foundation

public extension PluginHostServiceID {
    /// Project environment, Maven and run workflows, using the shared IDE API v1 contract.
    static let ideCapabilities = PluginHostServiceID(rawValue: "dev.lithe.host.ide-capabilities")
}

/// Uses the same explicitly authorized project capability surface as MCP.
/// JSON arguments/results follow shared/contracts/ide-api/v1.md; no app types escape.
@MainActor
public protocol IDECapabilitiesProviding: AnyObject {
    func authorizedWorkspaceIDs() -> [String]
    func call(workspaceID: String, name: String, argumentsJSON: String) async -> String
}
