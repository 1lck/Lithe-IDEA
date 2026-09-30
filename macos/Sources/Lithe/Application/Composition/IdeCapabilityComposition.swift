import Foundation
import LitheCoreContracts

extension AppModel: IdeCapabilityActions {
    var ideHostTransport: (any IdeHostTransport)? { services.ideHostTransport }
    func registerIdeCapabilities(_ feature: IdeCapabilitiesFeatureModel) { services.ideCapabilityRegistry?.register(feature, workspaceID: id.uuidString) }
    func unregisterIdeCapabilities() { services.ideCapabilityRegistry?.unregister(workspaceID: id.uuidString) }
    func startAPIConfiguration(_ configuration: RunConfiguration) async { await performStartRunConfiguration(configuration, allowDeferred: false) }
    func showMavenOutput() { showToolWindow(.mavenOutput) }
    func copyIdeConfiguration(_ text: String) { platformUI.copyToClipboard(text) }
}
