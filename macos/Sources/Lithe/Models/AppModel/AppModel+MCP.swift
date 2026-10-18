import Foundation

/// Application wiring for the MCP server library.
///
/// Project-level Lithe registration is triggered by the MCP grant lifecycle:
/// `IdeCapabilitiesFeatureModel` forwards the helper command it received so the
/// library can write the same server into the project's Agent configuration.
extension AppModel: McpServerLibraryActions {
    var mcpConfigurationStore: (any McpConfigurationStore)? {
        services.mcpConfigurationStore
    }

    var mcpWorkspaceURL: URL? { workspaceURL }

    var mcpLedgerStore: any KeyValueStore { services.store }

    func registerLitheMcpServer(_ server: McpServerDefinition) {
        mcpServerLibrary.registerLitheServer(server)
    }

    func unregisterLitheMcpServer() {
        mcpServerLibrary.unregisterLitheServer()
    }
}
