import Combine
import Foundation

/// Owns one paginated search. Cancellation and request identity prevent a late
/// response from replacing the results of a newer query.
@MainActor
final class McpRegistryFeatureModel: ObservableObject {
    @Published private(set) var entries: [McpRegistryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var nextCursor: String?
    @Published private(set) var canRetryDirectly = false
    private let registry: (any McpRegistryProviding)?
    private let featured: [McpRegistryEntry]
    private let featuredError: String?
    private var requestID = UUID()
    private var query = ""
    private var route = McpRegistryRoute.system

    init(registry: (any McpRegistryProviding)?) {
        self.registry = registry
        do {
            featured = try registry?.featured().entries ?? []
            featuredError = nil
        } catch {
            featured = []
            featuredError = String(localized: "The featured MCP catalog could not be loaded.")
        }
        entries = featured
    }

    func search(_ text: String, loadMore: Bool = false, route: McpRegistryRoute = .system) async {
        let id = UUID()
        requestID = id
        let search = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = loadMore && search == query && route == self.route ? nextCursor : nil
        if cursor == nil {
            entries = featured.filter {
                search.isEmpty || [$0.id, $0.title, $0.publisher ?? "", $0.summary,
                    String(localized: String.LocalizationValue($0.summary))]
                    .contains { $0.localizedCaseInsensitiveContains(search) }
            }
            nextCursor = nil
        }
        query = search
        self.route = route
        error = featuredError
        canRetryDirectly = false
        // The landing page is release-owned content, available before any request.
        // Only explicit searches ask the public Registry to extend these results.
        guard !search.isEmpty else { isLoading = false; return }
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            guard let registry else { throw McpLibraryError.unavailable }
            let page = try await registry.search(query: search, cursor: cursor, route: route)
            guard requestID == id, !Task.isCancelled else { return }
            var seen = Set(entries.map(\.id))
            var connections = Set(entries.compactMap { connection(of: $0) })
            entries += page.entries.filter { entry in
                guard seen.insert(entry.id).inserted else { return false }
                return connection(of: entry).map { connections.insert($0).inserted } ?? true
            }
            nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            canRetryDirectly = route == .system
            switch error as? McpRegistryError {
            case .secureConnection:
                self.error = String(localized: "A secure connection to the MCP Registry could not be established. Check the proxy or retry directly.")
            case .timeout:
                self.error = String(localized: "The MCP Registry request timed out. Try again.")
            case .offline:
                self.error = String(localized: "The MCP Registry is unreachable. Check the network or proxy.")
            default:
                canRetryDirectly = false
                self.error = String(localized: "The MCP Registry could not be loaded. Try again or add a server manually.")
            }
        }
    }

    private func connection(of entry: McpRegistryEntry) -> McpServerDefinition? {
        guard var definition = entry.draft else { return nil }
        definition.name = ""
        definition.definitionHash = ""
        definition.sourceHash = nil
        return definition
    }
}
