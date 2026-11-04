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
    var recentSessions: Int? = nil
    var channelPrefixes: [String] = []
    var levels: [String]? = nil
    var expression: String? = nil
    var filterSince: String? = nil
    var filterUntil: String? = nil
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
    var estimatedBytes: UInt64 = 0
    var sessions: [String] = []
    var sessionStart: Date? = nil
    var diskBytes: UInt64 = 0
}

struct ApplicationLogStatus: Sendable {
    let diagnosticEnabled: Bool
    let diagnosticCategory: String?
    let diskBytes: UInt64
}

protocol ApplicationLogging: Sendable {
    func status() async throws -> ApplicationLogStatus
    func collect(query: ApplicationLogQuery) async throws -> ApplicationLogCollection
    func configureDiagnostic(category: String?, enabled: Bool) async
    func clear() async throws
    func changeDirectory(to directory: URL) async throws
}

extension ApplicationLogging {
    func status() async throws -> ApplicationLogStatus {
        let collection = try await collect(query: .init())
        return .init(diagnosticEnabled: collection.diagnosticEnabled,
            diagnosticCategory: collection.diagnosticCategory, diskBytes: collection.diskBytes)
    }
    func changeDirectory(to directory: URL) async throws { throw CocoaError(.featureUnsupported) }
}

/// Window requests carry only presentation selections; Core owns every predicate.
struct LogWindowQuery: Codable, Sendable, Equatable {
    var session = "current"
    var expression = ""
    var channelPrefixes: [String] = []
    var levels = ["DEBUG", "INFO", "WARN", "ERROR"]
    var since: String? = nil
    var until: String? = nil
    var op: String? = nil
    var afterSequences: [String: UInt64]? = nil
}
struct LogWindowBatch: Sendable { let channel: String; let line: String }
struct LogWindowCollection: Sendable {
    let result: RustCoreBridge.LogQueryResult
    let directory: URL
    let currentSessionPath: String
    let dropped: Int
    let writeFailures: Int
    let diagnosticCategory: String?
    let diagnosticRemaining: TimeInterval
}
struct LogWindowLiveSummary: Sendable {
    let histogram: RustCoreBridge.LogHistogram?
    let dropped: Int
    let writeFailures: Int
    let diagnosticCategory: String?
    let diagnosticRemaining: TimeInterval
}
protocol LogWindowLogging: Sendable {
    func windowLiveSummary(_ records: [RustCoreBridge.LogQueryRecord]) async throws -> LogWindowLiveSummary
    func queryWindow(_ query: LogWindowQuery) async throws -> LogWindowCollection
    func queryWindowBatch(_ entries: [LogWindowBatch], query: LogWindowQuery) async throws -> RustCoreBridge.LogQueryResult
    func subscribeWindow() async throws -> AsyncStream<[LogWindowBatch]>
    func parseWindowFilter(_ expression: String) async throws -> RustCoreBridge.LogFilterParse
    func composeWindowFilter(_ request: RustCoreBridge.LogComposeRequest) async throws -> String
    func formatWindowRecords(_ request: RustCoreBridge.LogFormatRequest) async throws -> String
    func windowEngineChannel(providerID: String) async throws -> String
    func configureDiagnostic(category: String?, enabled: Bool) async
}
