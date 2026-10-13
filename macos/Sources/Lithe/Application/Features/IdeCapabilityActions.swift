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
    func showMavenOutput()
    func copyIdeConfiguration(_ text: String)
}
