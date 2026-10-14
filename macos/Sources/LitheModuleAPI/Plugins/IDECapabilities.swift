import Foundation

/// Uses the same explicitly authorized project capability surface as MCP.
/// JSON arguments/results follow shared/contracts/ide-api/v1.md; no app types escape.
@MainActor
public protocol IDECapabilitiesProviding: AnyObject {
    func authorizedWorkspaceIDs() -> [String]
    func call(workspaceID: String, name: String, argumentsJSON: String) async -> String
}
