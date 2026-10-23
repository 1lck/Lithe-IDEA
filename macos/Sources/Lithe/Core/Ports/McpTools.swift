import Foundation

struct McpToolDescription: Decodable, Equatable, Identifiable, Sendable {
    let name: String
    let description: String
    var id: String { name }
}

struct McpProbeResult: Decodable, Sendable { let tools: [McpToolDescription] }
struct McpToolTarget: Sendable {
    let definition: McpServerDefinition
    let files: [McpConfigurationFile]
}
struct McpToolPermission: Decodable, Sendable {
    let name: String
    let enabled: Bool
    let editable: Bool
}

struct McpToolPolicySnapshot: Sendable {
    let id: UUID
    let agent: McpAgent
    let tools: [McpToolPermission]
    let previousSourceHash: String?
    let sourceHash: String?
}

/// Probe transport and native filesystem access remain behind a platform port.
@MainActor
protocol McpToolsManaging: AnyObject {
    func probe(_ definition: McpServerDefinition) async throws -> McpProbeResult
    func policy(for target: McpToolTarget, agent: McpAgent, tools: [String]) throws -> McpToolPolicySnapshot
    func setEnabled(_ enabled: Bool, tool: String, target: McpToolTarget, snapshot: McpToolPolicySnapshot) throws -> McpToolPolicySnapshot
    func commandLine(command: String, args: [String]) throws -> String
    func parseCommandLine(_ line: String) throws -> (command: String, args: [String])
    func release(_ snapshots: [McpToolPolicySnapshot])
    func validateRename(_ target: McpToolTarget) throws
    /// Called only after the native batch commits, for each renamed source file.
    func serverRenamed(from previousName: String, to name: String, in file: McpConfigurationFile)
}

extension McpToolsManaging {
    func validateRename(_ target: McpToolTarget) throws { }
    func serverRenamed(from previousName: String, to name: String, in file: McpConfigurationFile) { }
}
