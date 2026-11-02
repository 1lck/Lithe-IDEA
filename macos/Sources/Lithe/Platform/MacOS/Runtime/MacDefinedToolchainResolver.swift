import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Launch-only adapter for installed definitions. It owns no saved preferences and
/// never promotes a settings-page detection into execution authority.
@MainActor
final class MacDefinedToolchainResolver: DefinedToolchainResolving {
    var sources: @MainActor () -> [ToolchainSettingsPluginSource] = { [] }
    var discovery = MacToolchainDiscovery()

    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool) async throws -> MacToolchainDiscovery.Selection? {
        try await resolve(tool: tool, directory: directory, workspace: workspace, environment: environment,
                          minimumVersion: minimumVersion, projectCodeAllowed: projectCodeAllowed, fixed: nil)
    }

    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection?) async throws -> MacToolchainDiscovery.Selection? {
        let installed = sources()
        let discovery = self.discovery
        let localURL = workspace.appendingPathComponent(".lithe/toolchains/local.json")
        let worker = Task.detached(priority: .userInitiated) {
            let bytes = try MacToolchainSettingsLoader.safeNativeRead(localURL)
            let local: ToolingJSONValue
            if let bytes {
                local = try JSONDecoder().decode(ToolingJSONValue.self, from: bytes)
            } else {
                local = .object(["version": .number(1), "toolchains": .object([:])])
            }
            let result = try await discovery.resolve(.init(workspace: workspace, sources: installed, environment: environment),
                tool: tool, directory: directory, minimumVersion: minimumVersion, local: local, projectCodeAllowed: projectCodeAllowed, fixed: fixed)
            guard try MacToolchainSettingsLoader.safeNativeRead(localURL) == bytes else { throw CancellationError() }
            return result
        }
        let selected = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard sources() == installed else { throw CancellationError() }
        return selected
    }
}
