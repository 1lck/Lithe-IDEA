import Foundation
import LitheModuleAPI

extension RustCoreBridge {
    typealias LogScalar = CoreLogScalar
    struct LogInput: Encodable, Sendable {
        var ts: String
        var level: String
        var seq: UInt64
        var event: String
        var op: String?
        var msg: String
        var fields: [String: LogScalar]
        var channel: String? = nil
    }
    struct LogHeader: Encodable, Sendable {
        let session: String
        let pid: UInt32
        let app: String
        let channel: String
        let started: String
    }
    struct LogBatch: Encodable {
        let events: [LogInput]
        var validateCatalog = true
        var deduplicate = true
        var previousEvent: LogInput? = nil
        var headers: [LogHeader] = []
    }
    struct LogFailure: Decodable, Error, Sendable { let code: Int; let reason: String }
    struct LogEncoded: Decodable, Sendable { let line: String?; let channel: String?; let error: LogFailure? }
    struct LogBatchResult: Decodable { let results: [LogEncoded]; let headers: [LogEncoded]; let sessionPath: String? }
    struct LogDomainResult<T: Decodable>: Decodable {
        let result: T?
        let error: LogFailure?
        func get() throws -> T {
            if let error { throw error }
            guard let result else { throw CocoaError(.coderInvalidValue) }
            return result
        }
    }
    struct LogChannelRequest: Encodable { let channel: String; let rotationIndex: Int; let existingChannels: [String] }
    struct LogChannelResult: Decodable { let relativePath: String; let category: String; let pluginFilesPath: String? }
    struct LogSourceV2: Encodable { let relativePath: String; let text: String; var startsMidLine = false }
    struct LogQueryV2: Encodable {
        let sources: [LogSourceV2]
        let channelPrefixes: [String]
        let minimumLevel: String?
        let since: String?
        let until: String?
        let search: String?
        var limit = 2000
    }
    struct LogQueryRecord: Decodable {
        let line: String
        let relativePath: String
        let ts: String; let level: String; let seq: UInt64; let event: String
        let op: String?; let msg: String; let fields: [String: String]
    }
    struct LogQueryResult: Decodable {
        let records: [LogQueryRecord]
        let truncated: Bool
        let skippedInvalidLines: Int
    }
    struct LogRetentionFile: Encodable { let relativePath: String; let sizeBytes: Int; let modifiedAt: String }
    struct LogRetentionSession: Encodable { let name: String; let files: [LogRetentionFile] }
    struct LogRetentionLimits: Encodable { let totalBytes: Int }
    struct LogRetentionRequest: Encodable {
        let sessions: [LogRetentionSession]; let legacyFiles: [LogRetentionFile]
        let currentSession: String; let now: String; let limits: LogRetentionLimits; let startupCleanup: Bool
    }
    struct LogDeletion: Decodable { let relativePath: String; let directory: Bool }
    struct LogRetentionResult: Decodable { let deletions: [LogDeletion] }

    struct LogCollectionFile: Encodable, Sendable {
        let relativePath: String
        let sizeBytes: UInt64
        let modifiedAt: String
    }
    struct LogCollectionRequest: Encodable {
        let files: [LogCollectionFile]
        let currentSession: String
        let session: String
        let category: String?
    }
    struct LogTailRead: Decodable {
        let relativePath: String
        let offset: UInt64
        let maxBytes: Int
    }
    struct LogCollectionPlan: Decodable {
        let reads: [LogTailRead]
        let truncated: Bool
    }
    func planLogCollection(_ request: LogCollectionRequest) throws -> LogCollectionPlan {
        let response: LogDomainResult<LogCollectionPlan> = try executeResult(command: "diagnostics.planLogCollection", payload: request).get()
        return try response.get()
    }
    func logCategory(_ channel: String) throws -> String {
        let response: LogDomainResult<LogChannelResult> = try executeResult(command: "diagnostics.resolveLogChannel",
            payload: LogChannelRequest(channel: channel, rotationIndex: 0, existingChannels: [])).get()
        return try response.get().category
    }
    struct CoreLogDrain: Decodable { let events: [CoreLogRecord]; let dropped: UInt64 }
    func drainCoreLogEvents() throws -> CoreLogDrain {
        try executeResult(command: "diagnostics.drainCoreEvents", payload: [String: String]()).get()
    }

    func encodeLogs(_ request: LogBatch) throws -> LogBatchResult {
        try executeResult(command: "diagnostics.encodeLogBatch", payload: request).get()
    }
    private struct EngineLogSubjectRequest: Encodable {
        let role = "language_server"
        let providerId: String
    }
    struct EngineLogSubject: Decodable { let channel: String; let segment: String }
    func resolveEngineLogSubject(providerID: String) throws -> LogSegment? {
        let response: EngineLogSubject = try executeResult(command: "diagnostics.resolveEngineLogSubject",
            payload: EngineLogSubjectRequest(providerId: providerID)).get()
        return LogSegment(response.segment)
    }
    func resolveLogChannel(_ channel: String, rotation: Int = 0, existing: [String]) throws -> String {
        let response: LogDomainResult<LogChannelResult> = try executeResult(command: "diagnostics.resolveLogChannel",
            payload: LogChannelRequest(channel: channel, rotationIndex: rotation, existingChannels: existing)).get()
        return try response.get().relativePath
    }
    func pluginLogFilesPath(pluginID: String) throws -> String {
        let response: LogDomainResult<LogChannelResult> = try executeResult(command: "diagnostics.resolveLogChannel",
            payload: LogChannelRequest(channel: "plugins/" + pluginID + "/host", rotationIndex: 0, existingChannels: [])).get()
        guard let path = try response.get().pluginFilesPath else { throw CocoaError(.coderInvalidValue) }
        return path
    }
    private struct TraceRequest: Encodable { let sessionId: String; let enabled: Bool }
    func setLogSessionDiagnostics(sessionID: String, enabled: Bool) throws {
        let _: [String: String] = try executeResult(command: "lsp.setDetailedDiagnostics", payload: TraceRequest(sessionId: sessionID, enabled: enabled)).get()
    }
    func queryLogsV2(_ request: LogQueryV2) throws -> LogQueryResult {
        let response: LogDomainResult<LogQueryResult> = try executeResult(command: "diagnostics.queryLogsV2", payload: request).get()
        return try response.get()
    }
    func planLogRetention(_ request: LogRetentionRequest) throws -> LogRetentionResult {
        let response: LogDomainResult<LogRetentionResult> = try executeResult(command: "diagnostics.planLogRetention", payload: request).get()
        return try response.get()
    }
}
