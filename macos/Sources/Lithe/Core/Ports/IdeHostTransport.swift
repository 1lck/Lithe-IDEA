import Foundation

/// Local broker transport. The platform owns writable connection storage and helper discovery.
@MainActor
protocol IdeHostTransport {
    func open(workspace: URL, permissions: [String: Bool]) throws -> [String: Any]
    func control(_ action: String, arguments: [String: Any]) throws -> [String: Any]
}
