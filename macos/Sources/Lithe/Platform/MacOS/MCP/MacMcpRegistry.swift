import Foundation

/// Reads bounded public metadata into memory; no packages, images, credentials,
/// files or server processes are downloaded or launched by discovery.
@MainActor
final class MacMcpRegistry: McpRegistryProviding {
    private let core: RustCoreBridge
    private let systemSession: URLSession
    private let directSession: URLSession

    init(core: RustCoreBridge) {
        self.core = core
        func configuration() -> URLSessionConfiguration {
            let value = URLSessionConfiguration.ephemeral
            value.httpShouldSetCookies = false
            value.urlCredentialStorage = nil
            value.timeoutIntervalForRequest = 15
            value.timeoutIntervalForResource = 20
            return value
        }
        systemSession = URLSession(configuration: configuration())
        let direct = configuration()
        // An explicit page action chooses this route for public directory reads
        // only. It does not alter system proxies or any MCP server connection.
        direct.connectionProxyDictionary = [:]
        directSession = URLSession(configuration: direct)
    }

    deinit {
        systemSession.invalidateAndCancel()
        directSession.invalidateAndCancel()
    }

    func featured() throws -> McpRegistryPage {
        struct Payload: Encodable {}
        return try core.executeResult(command: "mcp.featuredRegistry", payload: Payload()).get()
    }

    func search(query: String, cursor: String?, route: McpRegistryRoute) async throws -> McpRegistryPage {
        do { return try await fetch(query: query, cursor: cursor, route: route) }
        catch let error as URLError {
            switch error.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                throw McpRegistryError.secureConnection
            case .timedOut: throw McpRegistryError.timeout
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
                throw McpRegistryError.offline
            default: throw error
            }
        }
    }

    private func fetch(query: String, cursor: String?, route: McpRegistryRoute) async throws -> McpRegistryPage {
        var components = URLComponents(string: "https://registry.modelcontextprotocol.io/v0.1/servers")!
        components.queryItems = [URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "version", value: "latest")]
        if !query.isEmpty { components.queryItems?.append(URLQueryItem(name: "search", value: query)) }
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        let session = route == .direct ? directSession : systemSession
        let content = try await Self.readPage(session: session, url: components.url!)
        struct Payload: Encodable { let content: String }
        return try core.executeResult(command: "mcp.parseRegistry", payload: Payload(content: content)).get()
    }

    // Keep per-byte iteration off the UI actor; only the final bounded text
    // returns to the main actor for Core normalization.
    nonisolated private static func readPage(session: URLSession, url: URL) async throws -> String {
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 1_048_576 else { throw McpRegistryError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw McpRegistryError.invalidResponse }
            data.append(byte)
        }
        guard let content = String(data: data, encoding: .utf8) else { throw McpRegistryError.invalidResponse }
        return content
    }

}
