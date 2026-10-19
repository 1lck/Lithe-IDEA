import Foundation
import LitheCoreContracts
import LitheExecutionModule

/// Application actions used by the workspace API without owning the application aggregate.
@MainActor
protocol IdeCapabilityActions: AnyObject {
    var id: UUID { get }
    var projectName: String { get }
    var currentWorkspaceIdentity: WorkspaceIdentity? { get }
    var runtimeFeature: RuntimeSettingsFeatureModel { get }
    var ideHostTransport: (any IdeHostTransport)? { get }
    func isCurrentWorkspace(_ identity: WorkspaceIdentity) -> Bool
    func activateExecutionModule() async -> ExecutionFeatureAccess?
    func ensureRunProjectReady(_ run: RunFeatureModel, for identity: WorkspaceIdentity) async -> RunProjectReadiness
    func prepareProjectRuntimeSettings() async
    func persistProjectRuntimeSettings()
    func reloadMavenProject(rescan: Bool) async
    func startAPIConfiguration(_ configuration: RunConfiguration) async
    func registerIdeCapabilities(_ feature: IdeCapabilitiesFeatureModel)
    func unregisterIdeCapabilities()
    /// Writes Lithe's helper into the open project's Agent MCP configuration.
    func registerLitheMcpServer(_ server: McpServerDefinition)
    /// Removes project-level Lithe entries Lithe still owns.
    func unregisterLitheMcpServer()
    func copyIdeConfiguration(_ text: String)
}

extension IdeCapabilityActions {
    /// Fixtures and compositions without Agent configuration management skip
    /// project registration instead of failing the grant.
    func registerLitheMcpServer(_ server: McpServerDefinition) {}
    func unregisterLitheMcpServer() {}
}
