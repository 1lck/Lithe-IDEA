import Foundation

/// Public directory metadata. A suggested recipe remains an editable draft.
struct McpRegistryEntry: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let version: String
    let website: URL?
    let draft: McpServerDefinition?
    var publisher: String? = nil
    var source: McpRegistrySource? = nil
    var setup: McpRegistrySetup? = nil
}

/// Incomplete, release-reviewed templates; never accepted from public metadata.
enum McpRegistrySetup: String, Decodable, Sendable {
    case bearerToken = "bearer-token"
    case allowedDirectories = "allowed-directories"
}

enum McpRegistrySource: String, Decodable, Sendable { case featured, registry }
enum McpRegistryRoute: Equatable, Sendable { case system, direct }
enum McpRegistryError: Error { case secureConnection, timeout, offline, invalidResponse }

struct McpRegistryPage: Decodable, Sendable {
    let entries: [McpRegistryEntry]
    let nextCursor: String?
}

@MainActor
protocol McpRegistryProviding {
    func featured() throws -> McpRegistryPage
    func search(query: String, cursor: String?, route: McpRegistryRoute) async throws -> McpRegistryPage
}
