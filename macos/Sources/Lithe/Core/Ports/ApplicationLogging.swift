import Foundation

/// Native logging boundary. Source text, editor buffers and process environments
/// never enter this port; callers send lifecycle facts and sanitized context.
struct ApplicationLogQuery: Codable, Sendable, Equatable {
    var category: String? = nil
    var minimumLevel: String? = nil
    var session: String = "current"
    var search: String? = nil
    var since: String? = nil
    var until: String? = nil
}

struct ApplicationLogFile: Sendable {
    let relativePath: String
    let data: Data
}

struct ApplicationLogCollection: Sendable {
    let files: [ApplicationLogFile]
    let content: String
    let truncated: Bool
    let effectiveDirectory: URL
    let diagnosticEnabled: Bool
    let droppedEvents: Int
    let writeFailures: Int
    var diagnosticCategory: String? = nil
}

protocol ApplicationLogging: Sendable {
    func record(level: String, scope: String, message: String, fields: [String: String])
    func collect(query: ApplicationLogQuery) async throws -> ApplicationLogCollection
    func configureDiagnostic(category: String?, enabled: Bool) async
    func clear() async throws
    func changeDirectory(to directory: URL) async throws
}

extension ApplicationLogging {
    func changeDirectory(to directory: URL) async throws { throw CocoaError(.featureUnsupported) }
}
