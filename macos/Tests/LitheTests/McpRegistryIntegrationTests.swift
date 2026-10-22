import Foundation
import Testing
@testable import Lithe

/// Opt-in public-network verification; ordinary unit tests remain offline.
@MainActor
struct McpRegistryIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_MCP_REGISTRY_INTEGRATION"] == "1"))
    func explicitlySelectedDirectRouteReadsAndPaginatesTheOfficialRegistry() async throws {
        let registry = MacMcpRegistry(core: RustCoreBridge())
        let first = try await registry.search(query: "mcp", cursor: nil, route: .direct)
        #expect(!first.entries.isEmpty)
        let cursor = try #require(first.nextCursor)
        let second = try await registry.search(query: "mcp", cursor: cursor, route: .direct)
        #expect(!second.entries.isEmpty)
        #expect(Set(first.entries.map(\.id)) != Set(second.entries.map(\.id)))
    }
}
